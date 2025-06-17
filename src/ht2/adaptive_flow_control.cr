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

      def initialize
        @bytes_consumed = 0_i64
        @last_update_time = Time.utc
        @update_count = 0
        @consumption_rate = 0.0
        @avg_increment_size = 0.0
        @stall_count = 0
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
      max_increment = (Security::MAX_WINDOW_SIZE - current_window).to_i32
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
      end

      @metrics.bytes_consumed += consumed
      @metrics.last_update_time = now
      @metrics.update_count += 1
    end

    private def update_dynamic_threshold : Nil
      # Adjust threshold based on consumption patterns
      if @metrics.consumption_rate > @initial_window_size
        # High consumption: update earlier
        @current_threshold = Math.min(@current_threshold + 0.02, @max_update_threshold)
      elsif @metrics.consumption_rate < @initial_window_size * 0.1
        # Low consumption: update later
        @current_threshold = Math.max(@current_threshold - 0.02, @min_update_threshold)
      end
    end

    private def calculate_dynamic_increment(current_window : Int64, consumed : Int64) : Int32
      # Base increment on consumption rate and patterns
      if @metrics.consumption_rate > @initial_window_size * 1.5
        # Very high consumption: give full window
        @initial_window_size.to_i32
      elsif @metrics.consumption_rate > @initial_window_size * 0.75
        # High consumption: give 75% of window
        (@initial_window_size * 0.75).to_i32
      elsif @metrics.consumption_rate < @initial_window_size * 0.25
        # Low consumption: give smaller increment
        Math.max(consumed * 3, @initial_window_size / 4).to_i32
      else
        # Moderate consumption: give half window
        (@initial_window_size / 2).to_i32
      end
    end
  end
end
