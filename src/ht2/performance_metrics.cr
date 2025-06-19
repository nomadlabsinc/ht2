module HT2
  # Performance metrics tracking for HTTP/2 connections
  class PerformanceMetrics
    # Tracks timing information for a stream
    struct StreamTiming
      getter created_at : Time
      getter? first_byte_at : Time?
      getter? completed_at : Time?

      def initialize
        @created_at = Time.utc
      end

      def record_first_byte : Nil
        @first_byte_at ||= Time.utc
      end

      def record_completion : Nil
        @completed_at = Time.utc
      end

      def time_to_first_byte : Time::Span?
        if t = @first_byte_at
          t - @created_at
        end
      end

      def total_duration : Time::Span?
        if t = @completed_at
          t - @created_at
        end
      end
    end

    # Throughput calculator with rolling window
    class ThroughputCalculator
      WINDOW_SIZE = 60 # seconds

      def initialize
        @bytes_samples = Array(Tuple(Time, UInt64)).new
        @mutex = Mutex.new
      end

      def record_bytes(bytes : UInt64) : Nil
        @mutex.synchronize do
          now = Time.utc
          @bytes_samples << {now, bytes}
          cleanup_old_samples(now)
        end
      end

      def bytes_per_second : Float64
        @mutex.synchronize do
          now = Time.utc
          cleanup_old_samples(now)

          return 0.0 if @bytes_samples.empty?

          total_bytes = @bytes_samples.sum(&.[1])
          duration = now - @bytes_samples.first[0]

          return 0.0 if duration.total_seconds <= 0

          total_bytes.to_f / duration.total_seconds
        end
      end

      private def cleanup_old_samples(now : Time) : Nil
        cutoff = now - WINDOW_SIZE.seconds
        @bytes_samples.reject! { |time, _| time < cutoff }
      end
    end

    @mutex : Mutex
    @stream_timings : Hash(UInt32, StreamTiming)
    @send_throughput : ThroughputCalculator
    @receive_throughput : ThroughputCalculator

    # Latency percentiles tracking
    @completed_latencies : Array(Float64)
    @ttfb_latencies : Array(Float64)

    # Security event tracking
    getter security_events : SecurityEventMetrics

    def initialize
      @mutex = Mutex.new
      @stream_timings = Hash(UInt32, StreamTiming).new
      @send_throughput = ThroughputCalculator.new
      @receive_throughput = ThroughputCalculator.new
      @completed_latencies = Array(Float64).new
      @ttfb_latencies = Array(Float64).new
      @security_events = SecurityEventMetrics.new
    end

    # Record stream lifecycle events
    def record_stream_created(stream_id : UInt32) : Nil
      @mutex.synchronize do
        @stream_timings[stream_id] = StreamTiming.new
      end
    end

    def record_stream_first_byte(stream_id : UInt32) : Nil
      @mutex.synchronize do
        @stream_timings[stream_id]?.try(&.record_first_byte)
      end
    end

    def record_stream_completed(stream_id : UInt32) : Nil
      @mutex.synchronize do
        timing = @stream_timings[stream_id]?
        return unless timing

        timing.record_completion

        # Record latency metrics
        if duration = timing.total_duration
          @completed_latencies << duration.total_milliseconds
          # Keep only recent samples
          @completed_latencies = @completed_latencies.last(1000)
        end

        if ttfb = timing.time_to_first_byte
          @ttfb_latencies << ttfb.total_milliseconds
          @ttfb_latencies = @ttfb_latencies.last(1000)
        end
      end
    end

    # Record throughput
    def record_bytes_sent(bytes : UInt64) : Nil
      @send_throughput.record_bytes(bytes)
    end

    def record_bytes_received(bytes : UInt64) : Nil
      @receive_throughput.record_bytes(bytes)
    end

    # Get current throughput
    def send_throughput_bps : Float64
      @send_throughput.bytes_per_second
    end

    def receive_throughput_bps : Float64
      @receive_throughput.bytes_per_second
    end

    # Calculate latency percentiles
    def latency_percentiles : NamedTuple(
      p50: Float64?,
      p90: Float64?,
      p95: Float64?,
      p99: Float64?)
      @mutex.synchronize do
        calculate_percentiles(@completed_latencies)
      end
    end

    def ttfb_percentiles : NamedTuple(
      p50: Float64?,
      p90: Float64?,
      p95: Float64?,
      p99: Float64?)
      @mutex.synchronize do
        calculate_percentiles(@ttfb_latencies)
      end
    end

    private def calculate_percentiles(values : Array(Float64)) : NamedTuple(
      p50: Float64?,
      p90: Float64?,
      p95: Float64?,
      p99: Float64?)
      return {p50: nil, p90: nil, p95: nil, p99: nil} if values.empty?

      sorted = values.sort

      {
        p50: percentile(sorted, 0.50),
        p90: percentile(sorted, 0.90),
        p95: percentile(sorted, 0.95),
        p99: percentile(sorted, 0.99),
      }
    end

    private def percentile(sorted : Array(Float64), p : Float64) : Float64
      index = (sorted.size * p).to_i
      index = sorted.size - 1 if index >= sorted.size
      sorted[index]
    end
  end

  # Security event metrics tracking
  class SecurityEventMetrics
    @mutex : Mutex

    # Attack detection counters
    getter rapid_reset_attempts : UInt64 = 0_u64
    getter settings_flood_attempts : UInt64 = 0_u64
    getter ping_flood_attempts : UInt64 = 0_u64
    getter priority_flood_attempts : UInt64 = 0_u64
    getter window_update_flood_attempts : UInt64 = 0_u64

    # Security violations
    getter header_size_violations : UInt64 = 0_u64
    getter stream_limit_violations : UInt64 = 0_u64
    getter frame_size_violations : UInt64 = 0_u64
    getter invalid_preface_attempts : UInt64 = 0_u64

    # Connection security events
    getter connections_rejected : UInt64 = 0_u64
    getter connections_rate_limited : UInt64 = 0_u64

    def initialize
      @mutex = Mutex.new
    end

    def record_rapid_reset_attempt : Nil
      @mutex.synchronize { @rapid_reset_attempts += 1 }
    end

    def record_settings_flood_attempt : Nil
      @mutex.synchronize { @settings_flood_attempts += 1 }
    end

    def record_ping_flood_attempt : Nil
      @mutex.synchronize { @ping_flood_attempts += 1 }
    end

    def record_priority_flood_attempt : Nil
      @mutex.synchronize { @priority_flood_attempts += 1 }
    end

    def record_window_update_flood_attempt : Nil
      @mutex.synchronize { @window_update_flood_attempts += 1 }
    end

    def record_header_size_violation : Nil
      @mutex.synchronize { @header_size_violations += 1 }
    end

    def record_stream_limit_violation : Nil
      @mutex.synchronize { @stream_limit_violations += 1 }
    end

    def record_frame_size_violation : Nil
      @mutex.synchronize { @frame_size_violations += 1 }
    end

    def record_invalid_preface : Nil
      @mutex.synchronize { @invalid_preface_attempts += 1 }
    end

    def record_connection_rejected : Nil
      @mutex.synchronize { @connections_rejected += 1 }
    end

    def record_connection_rate_limited : Nil
      @mutex.synchronize { @connections_rate_limited += 1 }
    end

    def snapshot : NamedTuple(
      attacks: NamedTuple(
        rapid_reset: UInt64,
        settings_flood: UInt64,
        ping_flood: UInt64,
        priority_flood: UInt64,
        window_update_flood: UInt64),
      violations: NamedTuple(
        header_size: UInt64,
        stream_limit: UInt64,
        frame_size: UInt64,
        invalid_preface: UInt64),
      connections: NamedTuple(
        rejected: UInt64,
        rate_limited: UInt64))
      @mutex.synchronize do
        {
          attacks: {
            rapid_reset:         @rapid_reset_attempts,
            settings_flood:      @settings_flood_attempts,
            ping_flood:          @ping_flood_attempts,
            priority_flood:      @priority_flood_attempts,
            window_update_flood: @window_update_flood_attempts,
          },
          violations: {
            header_size:     @header_size_violations,
            stream_limit:    @stream_limit_violations,
            frame_size:      @frame_size_violations,
            invalid_preface: @invalid_preface_attempts,
          },
          connections: {
            rejected:     @connections_rejected,
            rate_limited: @connections_rate_limited,
          },
        }
      end
    end
  end
end
