module HT2
  # Manages backpressure for HTTP/2 connections and streams
  class BackpressureManager
    # Tracks write pressure metrics
    class WritePressure
      getter pending_bytes : Int64
      getter pending_frames : Int32
      getter stall_count : Int32
      getter last_stall : Time?

      def initialize
        @pending_bytes = 0_i64
        @pending_frames = 0
        @stall_count = 0
        @last_stall = nil
      end

      def add_pending(bytes : Int64, frames : Int32 = 1) : Nil
        @pending_bytes += bytes
        @pending_frames += frames
      end

      def clear_pending(bytes : Int64, frames : Int32 = 1) : Nil
        @pending_bytes = Math.max(0_i64, @pending_bytes - bytes)
        @pending_frames = Math.max(0, @pending_frames - frames)
      end

      def record_stall : Nil
        @stall_count += 1
        @last_stall = Time.utc
      end

      def pressure_ratio(max_bytes : Int64) : Float64
        return 0.0 if max_bytes <= 0
        @pending_bytes.to_f / max_bytes.to_f
      end

      def high_pressure?(max_bytes : Int64 = DEFAULT_MAX_WRITE_BUFFER, threshold : Float64 = 0.8) : Bool
        pressure_ratio(max_bytes) > threshold
      end
    end

    DEFAULT_MAX_WRITE_BUFFER = 1024_i64 * 1024_i64 # 1MB
    DEFAULT_HIGH_WATERMARK   = 0.8
    DEFAULT_LOW_WATERMARK    = 0.5

    getter max_write_buffer : Int64
    getter high_watermark : Float64
    getter low_watermark : Float64

    @connection_pressure : WritePressure
    @stream_pressure : Hash(UInt32, WritePressure)
    @write_paused : Bool
    @pause_callbacks : Array(Proc(Nil))
    @resume_callbacks : Array(Proc(Nil))
    @mutex : Mutex

    def initialize(@high_watermark : Float64 = DEFAULT_HIGH_WATERMARK,
                   @low_watermark : Float64 = DEFAULT_LOW_WATERMARK,
                   @max_write_buffer : Int64 = DEFAULT_MAX_WRITE_BUFFER)
      @connection_pressure = WritePressure.new
      @stream_pressure = Hash(UInt32, WritePressure).new
      @write_paused = false
      @pause_callbacks = Array(Proc(Nil)).new
      @resume_callbacks = Array(Proc(Nil)).new
      @mutex = Mutex.new
    end

    def track_write(bytes : Int64, stream_id : UInt32?) : Nil
      @mutex.synchronize do
        @connection_pressure.add_pending(bytes)

        if stream_id
          pressure = @stream_pressure[stream_id] ||= WritePressure.new
          pressure.add_pending(bytes)
        end

        check_pressure
      end
    end

    def complete_write(bytes : Int64, stream_id : UInt32?) : Nil
      @mutex.synchronize do
        @connection_pressure.clear_pending(bytes)

        if stream_id && (pressure = @stream_pressure[stream_id]?)
          pressure.clear_pending(bytes)
          @stream_pressure.delete(stream_id) if pressure.pending_bytes == 0
        end

        check_pressure
      end
    end

    def should_pause? : Bool
      @connection_pressure.high_pressure?(@max_write_buffer, @high_watermark)
    end

    def should_resume? : Bool
      @connection_pressure.pressure_ratio(@max_write_buffer) < @low_watermark
    end

    def paused? : Bool
      @write_paused
    end

    def on_pause(&block : Proc(Nil)) : Nil
      @mutex.synchronize { @pause_callbacks << block }
    end

    def on_resume(&block : Proc(Nil)) : Nil
      @mutex.synchronize { @resume_callbacks << block }
    end

    def wait_for_capacity(timeout : Time::Span = 100.milliseconds) : Bool
      return true unless @write_paused
      wait_until_resumed(timeout)
    end

    private def wait_until_resumed(timeout : Time::Span) : Bool
      deadline = Time.utc + timeout
      while @write_paused && Time.utc < deadline
        sleep 10.milliseconds
      end
      !@write_paused
    end

    def stream_pressure(stream_id : UInt32) : Float64
      @mutex.synchronize do
        calculate_stream_pressure(stream_id)
      end
    end

    private def calculate_stream_pressure(stream_id : UInt32) : Float64
      pressure = @stream_pressure[stream_id]?
      return 0.0 unless pressure
      per_stream_limit = @max_write_buffer // 4
      pressure.pending_bytes.to_f / per_stream_limit.to_f
    end

    def connection_metrics : NamedTuple(pending_bytes: Int64, pending_frames: Int32, pressure: Float64)
      @mutex.synchronize do
        {
          pending_bytes:  @connection_pressure.pending_bytes,
          pending_frames: @connection_pressure.pending_frames,
          pressure:       @connection_pressure.pressure_ratio(@max_write_buffer),
        }
      end
    end

    private def check_pressure : Nil
      if should_pause? && !@write_paused
        @write_paused = true
        @pause_callbacks.each(&.call)
      elsif should_resume? && @write_paused
        @write_paused = false
        @resume_callbacks.each(&.call)
      end
    end
  end
end
