module HT2
  # Adaptive flow control manager that dynamically adjusts window update
  # strategies based on data consumption patterns and network conditions
  class AdaptiveFlowControl
    # Window update strategies
    enum Strategy
      # Conservative: Update when window drops below 25%
      CONSERVATIVE
      # Moderate: Update when window drops below 50% (current default)
      MODERATE
      # Aggressive: Update when window drops below 75%
      AGGRESSIVE
      # Dynamic: Adjust threshold based on consumption rate
      DYNAMIC
    end

    # Metrics for a single stream or connection
    struct FlowMetrics
      property bytes_consumed : Int64
      property last_update_time : Time
      property update_count : Int32
      property consumption_rate : Float64 # bytes per second
      property avg_increment_size : Float64
      property stall_count : Int32 # Number of times window hit zero
      property? burst_detected : Bool
      property last_burst_time : Time?
      property smoothed_rate : Float64 # Smoothed consumption rate
      property rate_variance : Float64 # Variance in consumption rate

      def initialize
        @bytes_consumed = 0_i64
        @last_update_time = Time.utc
        @update_count = 0
        @consumption_rate = 0.0
        @avg_increment_size = 0.0
        @stall_count = 0
        @burst_detected = false
        @last_burst_time = nil
        @smoothed_rate = 0.0
        @rate_variance = 0.0
      end
    end

    getter strategy : Strategy
    property metrics : FlowMetrics
    property initial_window_size : Int64
    property min_update_threshold : Float64 # Minimum threshold (0.1 = 10%)
    property max_update_threshold : Float64 # Maximum threshold (0.9 = 90%)
    property current_threshold : Float64    # Current dynamic threshold

    def initialize(@initial_window_size : Int64, @strategy : Strategy = Strategy::MODERATE)
      @metrics = FlowMetrics.new
      @min_update_threshold = 0.1
      @max_update_threshold = 0.9
      @current_threshold = case @strategy
                           when Strategy::CONSERVATIVE then 0.25
                           when Strategy::MODERATE     then 0.5
                           when Strategy::AGGRESSIVE   then 0.75
                           when Strategy::DYNAMIC      then 0.5 # Start moderate
                           else                             0.5
                           end
    end

    # Check if window update is needed based on current window size
    def needs_update?(current_window : Int64, available_window : Int64) : Bool
      return false if current_window <= 0

      window_ratio = available_window.to_f / current_window.to_f

      case @strategy
      when Strategy::DYNAMIC
        # Adapt threshold based on consumption rate
        update_dynamic_threshold
      end

      window_ratio < @current_threshold
    end

    # Calculate optimal window increment based on consumption patterns
    def calculate_increment(current_window : Int64, consumed : Int64) : Int32
      update_metrics(consumed)

      increment = case @strategy
                  when Strategy::CONSERVATIVE
                    # Small increments to avoid over-allocation
                    Math.min(@initial_window_size / 4, consumed * 2).to_i32
                  when Strategy::MODERATE
                    # Restore to half of initial window size
                    (@initial_window_size / 2).to_i32
                  when Strategy::AGGRESSIVE
                    # Restore to full window size
                    @initial_window_size.to_i32
                  when Strategy::DYNAMIC
                    calculate_dynamic_increment(current_window, consumed)
                  else
                    (@initial_window_size / 2).to_i32
                  end

      # Ensure increment doesn't exceed maximum window size
      max_possible = Security::MAX_WINDOW_SIZE - current_window
      return 0 if max_possible <= 0

      max_increment = Math.min(max_possible, Int32::MAX.to_i64).to_i32
      Math.min(increment, max_increment)
    end

    # Update flow control strategy based on network conditions
    def adapt_strategy(rtt_ms : Float64? = nil, loss_rate : Float64? = nil) : Nil
      return unless @strategy.dynamic?

      # If we have high RTT or packet loss, be more conservative
      if rtt_ms && rtt_ms > 100.0
        @current_threshold = Math.max(@current_threshold - 0.05, @min_update_threshold)
      elsif loss_rate && loss_rate > 0.01
        @current_threshold = Math.max(@current_threshold - 0.1, @min_update_threshold)
      elsif @metrics.stall_count > 0
        # If we've had stalls, update more aggressively
        @current_threshold = Math.min(@current_threshold + 0.1, @max_update_threshold)
        @metrics.stall_count = 0 # Reset after adaptation
      elsif @metrics.consumption_rate > @initial_window_size * 2
        # High consumption rate, update more aggressively
        @current_threshold = Math.min(@current_threshold + 0.05, @max_update_threshold)
      end
    end

    # Record that window hit zero (stalled)
    def record_stall : Nil
      @metrics.stall_count += 1
    end

    private def update_metrics(consumed : Int64) : Nil
      now = Time.utc
      elapsed = (now - @metrics.last_update_time).total_seconds

      if elapsed > 0
        # Update consumption rate (exponential moving average)
        instant_rate = consumed.to_f / elapsed

        @metrics.consumption_rate = if @metrics.update_count == 0
                                      instant_rate
                                    else
                                      @metrics.consumption_rate * 0.7 + instant_rate * 0.3
                                    end

        # Update smoothed rate with longer window for stability
        @metrics.smoothed_rate = if @metrics.update_count == 0
                                   instant_rate
                                 else
                                   @metrics.smoothed_rate * 0.9 + instant_rate * 0.1
                                 end

        # Track rate variance for burst detection
        if @metrics.update_count > 2 # Need at least 3 samples for meaningful comparison
          rate_diff = (instant_rate - @metrics.smoothed_rate).abs
          @metrics.rate_variance = @metrics.rate_variance * 0.8 + rate_diff * 0.2

          # Detect burst: instant rate is 3x the smoothed rate AND above window size
          if instant_rate > @metrics.smoothed_rate * 3.0 && instant_rate > @initial_window_size.to_f * 1.5
            @metrics.burst_detected = true
            @metrics.last_burst_time = now
          elsif @metrics.burst_detected?
            # Check if burst has ended (rate dropped significantly)
            if instant_rate < @metrics.smoothed_rate * 1.5 || instant_rate < @initial_window_size.to_f
              @metrics.burst_detected = false
            end
          end
        end
      end

      @metrics.bytes_consumed += consumed
      @metrics.last_update_time = now
      @metrics.update_count += 1
    end

    private def update_dynamic_threshold : Nil
      # Adjust threshold based on consumption patterns and burst detection
      if @metrics.burst_detected?
        # During burst: update very early to keep data flowing
        @current_threshold = Math.min(0.85, @max_update_threshold)
      elsif @metrics.stall_count > 0
        # After stalls: update earlier to prevent future stalls
        target_threshold = Math.min(@current_threshold + 0.15, @max_update_threshold)
        @current_threshold += (target_threshold - @current_threshold) * 0.3
      elsif @metrics.rate_variance > @initial_window_size * 0.3
        # High variance: update moderately early
        target_threshold = Math.min(0.7, @max_update_threshold)
        @current_threshold += (target_threshold - @current_threshold) * 0.1
      elsif @metrics.consumption_rate > @initial_window_size * 1.2
        # High stable consumption: gradually increase threshold
        @current_threshold = Math.min(@current_threshold + 0.03, @max_update_threshold)
      elsif @metrics.consumption_rate < @initial_window_size * 0.2
        # Low consumption: gradually decrease threshold
        @current_threshold = Math.max(@current_threshold - 0.03, @min_update_threshold)
      else
        # Normal consumption: slowly converge to moderate threshold
        target = 0.5
        @current_threshold += (target - @current_threshold) * 0.05
      end
    end

    private def calculate_dynamic_increment(current_window : Int64, consumed : Int64) : Int32
      # Calculate base increment based on multiple factors
      base_increment = if @metrics.burst_detected?
                         # During burst: allocate aggressively
                         rate_based = Math.min(@metrics.consumption_rate * 2, Int32::MAX.to_f).to_i64
                         Math.max(@initial_window_size, rate_based).to_i32
                       elsif @metrics.stall_count > 0
                         # After stalls: increase allocation to prevent future stalls
                         rate_based = Math.min(@metrics.consumption_rate * 1.5, Int32::MAX.to_f).to_i64
                         Math.max(@initial_window_size, rate_based).to_i32
                       elsif @metrics.rate_variance > @initial_window_size * 0.5
                         # High variance: allocate for peak consumption
                         rate_based = Math.min(@metrics.consumption_rate * 1.25, Int32::MAX.to_f).to_i64
                         Math.max((@initial_window_size * 0.75).to_i64, rate_based).to_i32
                       else
                         # Stable consumption: use predictive allocation
                         predicted_consumption = predict_next_consumption(consumed)
                         Math.max(predicted_consumption, (@initial_window_size / 2).to_i32)
                       end

      # Apply bounds and safety margins with overflow protection
      min_increment = Math.min(Math.max(consumed * 2, @initial_window_size / 4), Int32::MAX.to_i64).to_i32
      max_increment = Math.min(@initial_window_size * 2, Int32::MAX.to_i64).to_i32

      Math.min(Math.max(base_increment, min_increment), max_increment)
    end

    private def predict_next_consumption(recent_consumed : Int64) : Int32
      # Use weighted average of recent and smoothed consumption rates
      weight = Math.min(@metrics.update_count / 10.0, 0.8)
      predicted_rate = @metrics.smoothed_rate * weight + @metrics.consumption_rate * (1 - weight)

      # Add margin based on variance
      margin = 1.0 + Math.min(@metrics.rate_variance / @initial_window_size, 0.5)

      # Prevent overflow
      result = predicted_rate * margin
      return Int32::MAX if result > Int32::MAX

      result.to_i32
    end
  end
end
