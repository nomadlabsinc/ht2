module HT2
  # Protection against CVE-2023-44487 (Rapid Reset Attack)
  # This attack involves rapidly creating and canceling HTTP/2 streams
  # to exhaust server resources.
  class RapidResetProtection
    # Track stream creation and cancellation patterns
    struct StreamMetrics
      property created_at : Time
      property cancelled_at : Time?
      property? headers_received : Bool
      property? data_received : Bool
      property lifetime_ms : Float64?

      def initialize(@created_at : Time)
        @headers_received = false
        @data_received = false
        @cancelled_at = nil
        @lifetime_ms = nil
      end

      def cancel(time : Time) : Nil
        @cancelled_at = time
        @lifetime_ms = (time - @created_at).total_milliseconds
      end

      def rapid_cancel? : Bool
        lifetime = @lifetime_ms
        return false unless lifetime
        # Consider it rapid if cancelled within 100ms without receiving data
        lifetime < 100.0 && !data_received?
      end
    end

    # Configuration for rapid reset protection
    struct Config
      property max_streams_per_second : Int32
      property max_rapid_resets_per_minute : Int32
      property rapid_reset_threshold_ms : Float64
      property ban_duration : Time::Span
      property pending_stream_limit : Int32

      def initialize(
        @max_streams_per_second : Int32 = 100,
        @max_rapid_resets_per_minute : Int32 = 50,
        @rapid_reset_threshold_ms : Float64 = 100.0,
        @ban_duration : Time::Span = 5.minutes,
        @pending_stream_limit : Int32 = 1000,
      )
      end
    end

    getter config : Config
    private getter stream_metrics : Hash(UInt32, StreamMetrics)
    private getter rapid_reset_counts : Hash(String, Int32) # Per IP/connection
    private getter banned_until : Hash(String, Time)
    private getter stream_creation_times : Array(Time)
    private getter pending_streams : Set(UInt32)
    private getter cleanup_fiber : Fiber

    def initialize(@config : Config = Config.new)
      @stream_metrics = Hash(UInt32, StreamMetrics).new
      @rapid_reset_counts = Hash(String, Int32).new
      @banned_until = Hash(String, Time).new
      @stream_creation_times = Array(Time).new
      @pending_streams = Set(UInt32).new
      @cleanup_fiber = spawn { cleanup_loop }
    end

    # Check if connection is banned
    def banned?(connection_id : String) : Bool
      if ban_time = @banned_until[connection_id]?
        if Time.utc > ban_time
          @banned_until.delete(connection_id)
          false
        else
          true
        end
      else
        false
      end
    end

    # Record new stream creation
    def record_stream_created(stream_id : UInt32, connection_id : String) : Bool
      return false if banned?(connection_id)

      # Check pending stream limit
      if @pending_streams.size >= @config.pending_stream_limit
        ban_connection(connection_id, "Exceeded pending stream limit")
        return false
      end

      # Check stream creation rate
      now = Time.utc
      @stream_creation_times << now
      cleanup_old_creation_times(now)

      if @stream_creation_times.size > @config.max_streams_per_second
        ban_connection(connection_id, "Exceeded stream creation rate")
        return false
      end

      @stream_metrics[stream_id] = StreamMetrics.new(now)
      @pending_streams << stream_id
      true
    end

    # Record headers received for stream
    def record_headers_received(stream_id : UInt32) : Nil
      if metrics = @stream_metrics[stream_id]?
        metrics.headers_received = true
        @pending_streams.delete(stream_id)
      end
    end

    # Record data received for stream
    def record_data_received(stream_id : UInt32) : Nil
      if metrics = @stream_metrics[stream_id]?
        metrics.data_received = true
        @pending_streams.delete(stream_id)
      end
    end

    # Record stream cancellation (RST_STREAM)
    def record_stream_cancelled(stream_id : UInt32, connection_id : String) : Bool
      return false if banned?(connection_id)

      metrics = @stream_metrics[stream_id]?
      return true unless metrics # Stream not tracked

      now = Time.utc
      metrics.cancel(now)
      @pending_streams.delete(stream_id)

      # Check if this was a rapid reset
      if metrics.rapid_cancel?
        increment_rapid_reset_count(connection_id)

        # Check if connection should be banned
        if exceeds_rapid_reset_limit?(connection_id)
          ban_connection(connection_id, "Rapid reset attack detected")
          return false
        end
      end

      true
    end

    # Record normal stream closure
    def record_stream_closed(stream_id : UInt32) : Nil
      @stream_metrics.delete(stream_id)
      @pending_streams.delete(stream_id)
    end

    # Get current metrics for monitoring
    def metrics : NamedTuple(
      active_streams: Int32,
      pending_streams: Int32,
      banned_connections: Int32,
      rapid_reset_counts: Hash(String, Int32))
      {
        active_streams:     @stream_metrics.size,
        pending_streams:    @pending_streams.size,
        banned_connections: @banned_until.size,
        rapid_reset_counts: @rapid_reset_counts.dup,
      }
    end

    private def increment_rapid_reset_count(connection_id : String) : Nil
      @rapid_reset_counts[connection_id] ||= 0
      @rapid_reset_counts[connection_id] += 1
    end

    private def exceeds_rapid_reset_limit?(connection_id : String) : Bool
      count = @rapid_reset_counts[connection_id]? || 0
      count > @config.max_rapid_resets_per_minute
    end

    private def ban_connection(connection_id : String, reason : String) : Nil
      Log.warn { "Banning connection #{connection_id}: #{reason}" }
      @banned_until[connection_id] = Time.utc + @config.ban_duration
    end

    private def cleanup_old_creation_times(now : Time) : Nil
      cutoff = now - 1.second
      @stream_creation_times.reject! { |time| time < cutoff }
    end

    private def cleanup_loop : Nil
      loop do
        sleep 1.minute

        # Clean up old metrics
        now = Time.utc
        old_stream_cutoff = now - 5.minutes

        @stream_metrics.reject! do |_, metrics|
          metrics.created_at < old_stream_cutoff
        end

        # Reset rapid reset counts periodically
        @rapid_reset_counts.clear

        # Clean up expired bans
        @banned_until.reject! do |_, ban_time|
          now > ban_time
        end
      end
    end
  end
end
