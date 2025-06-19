require "./frames"

module HT2
  # Tracks comprehensive metrics for HTTP/2 connections
  class ConnectionMetrics
    # Frame type counters
    struct FrameCounters
      getter data_frames : UInt64 = 0_u64
      getter headers_frames : UInt64 = 0_u64
      getter priority_frames : UInt64 = 0_u64
      getter rst_stream_frames : UInt64 = 0_u64
      getter settings_frames : UInt64 = 0_u64
      getter push_promise_frames : UInt64 = 0_u64
      getter ping_frames : UInt64 = 0_u64
      getter goaway_frames : UInt64 = 0_u64
      getter window_update_frames : UInt64 = 0_u64
      getter continuation_frames : UInt64 = 0_u64

      def increment(frame_type : FrameType) : Nil
        case frame_type
        when FrameType::DATA          then @data_frames += 1
        when FrameType::HEADERS       then @headers_frames += 1
        when FrameType::PRIORITY      then @priority_frames += 1
        when FrameType::RST_STREAM    then @rst_stream_frames += 1
        when FrameType::SETTINGS      then @settings_frames += 1
        when FrameType::PUSH_PROMISE  then @push_promise_frames += 1
        when FrameType::PING          then @ping_frames += 1
        when FrameType::GOAWAY        then @goaway_frames += 1
        when FrameType::WINDOW_UPDATE then @window_update_frames += 1
        when FrameType::CONTINUATION  then @continuation_frames += 1
        end
      end

      def total : UInt64
        @data_frames + @headers_frames + @priority_frames + @rst_stream_frames +
          @settings_frames + @push_promise_frames + @ping_frames + @goaway_frames +
          @window_update_frames + @continuation_frames
      end
    end

    # Error counters by error code
    struct ErrorCounters
      getter protocol_errors : UInt64 = 0_u64
      getter internal_errors : UInt64 = 0_u64
      getter flow_control_errors : UInt64 = 0_u64
      getter settings_timeout_errors : UInt64 = 0_u64
      getter stream_closed_errors : UInt64 = 0_u64
      getter frame_size_errors : UInt64 = 0_u64
      getter refused_stream_errors : UInt64 = 0_u64
      getter cancel_errors : UInt64 = 0_u64
      getter compression_errors : UInt64 = 0_u64
      getter connect_errors : UInt64 = 0_u64
      getter enhance_your_calm_errors : UInt64 = 0_u64
      getter inadequate_security_errors : UInt64 = 0_u64
      getter http_1_1_required_errors : UInt64 = 0_u64

      def increment(error_code : ErrorCode) : Nil
        case error_code
        when ErrorCode::PROTOCOL_ERROR      then @protocol_errors += 1
        when ErrorCode::INTERNAL_ERROR      then @internal_errors += 1
        when ErrorCode::FLOW_CONTROL_ERROR  then @flow_control_errors += 1
        when ErrorCode::SETTINGS_TIMEOUT    then @settings_timeout_errors += 1
        when ErrorCode::STREAM_CLOSED       then @stream_closed_errors += 1
        when ErrorCode::FRAME_SIZE_ERROR    then @frame_size_errors += 1
        when ErrorCode::REFUSED_STREAM      then @refused_stream_errors += 1
        when ErrorCode::CANCEL              then @cancel_errors += 1
        when ErrorCode::COMPRESSION_ERROR   then @compression_errors += 1
        when ErrorCode::CONNECT_ERROR       then @connect_errors += 1
        when ErrorCode::ENHANCE_YOUR_CALM   then @enhance_your_calm_errors += 1
        when ErrorCode::INADEQUATE_SECURITY then @inadequate_security_errors += 1
        when ErrorCode::HTTP_1_1_REQUIRED   then @http_1_1_required_errors += 1
        end
      end

      def total : UInt64
        @protocol_errors + @internal_errors + @flow_control_errors +
          @settings_timeout_errors + @stream_closed_errors + @frame_size_errors +
          @refused_stream_errors + @cancel_errors + @compression_errors +
          @connect_errors + @enhance_your_calm_errors + @inadequate_security_errors +
          @http_1_1_required_errors
      end
    end

    @started_at : Time
    @mutex : Mutex

    # Connection-level counters
    getter streams_created : UInt64 = 0_u64
    getter streams_closed : UInt64 = 0_u64
    getter bytes_sent : UInt64 = 0_u64
    getter bytes_received : UInt64 = 0_u64
    getter current_streams : Int32 = 0_i32
    getter max_concurrent_streams : Int32 = 0_i32

    # Frame counters
    getter frames_sent : FrameCounters
    getter frames_received : FrameCounters

    # Error counters
    getter errors_sent : ErrorCounters
    getter errors_received : ErrorCounters

    # Flow control metrics
    getter flow_control_stalls : UInt64 = 0_u64
    getter window_updates_sent : UInt64 = 0_u64
    getter window_updates_received : UInt64 = 0_u64

    # Performance metrics
    getter last_activity_at : Time
    getter? goaway_sent : Bool = false
    getter? goaway_received : Bool = false

    def initialize
      @started_at = Time.utc
      @last_activity_at = @started_at
      @frames_sent = FrameCounters.new
      @frames_received = FrameCounters.new
      @errors_sent = ErrorCounters.new
      @errors_received = ErrorCounters.new
      @mutex = Mutex.new
    end

    # Record a frame being sent
    def record_frame_sent(frame : Frame) : Nil
      @mutex.synchronize do
        @frames_sent.increment(frame.type)
        @last_activity_at = Time.utc

        # Track specific frame types
        case frame
        when DataFrame
          bytes = frame.data.size
          @bytes_sent += bytes
        when GoAwayFrame
          @goaway_sent = true
          @errors_sent.increment(frame.error_code)
        when WindowUpdateFrame
          @window_updates_sent += 1
        when RstStreamFrame
          @errors_sent.increment(frame.error_code)
        end
      end
    end

    # Record a frame being received
    def record_frame_received(frame : Frame) : Nil
      @mutex.synchronize do
        @frames_received.increment(frame.type)
        @last_activity_at = Time.utc

        # Track specific frame types
        case frame
        when DataFrame
          bytes = frame.data.size
          @bytes_received += bytes
        when GoAwayFrame
          @goaway_received = true
          @errors_received.increment(frame.error_code)
        when WindowUpdateFrame
          @window_updates_received += 1
        when RstStreamFrame
          @errors_received.increment(frame.error_code)
        end
      end
    end

    # Record stream lifecycle events
    def record_stream_created(stream_id : UInt32? = nil) : Nil
      @mutex.synchronize do
        @streams_created += 1
        @current_streams += 1
        @max_concurrent_streams = @current_streams if @current_streams > @max_concurrent_streams
        @last_activity_at = Time.utc
      end
    end

    def record_stream_closed(stream_id : UInt32? = nil) : Nil
      @mutex.synchronize do
        @streams_closed += 1
        @current_streams -= 1 if @current_streams > 0
        @last_activity_at = Time.utc
      end
    end

    # Record flow control events
    def record_flow_control_stall : Nil
      @mutex.synchronize do
        @flow_control_stalls += 1
      end
    end

    # Record bytes sent/received outside of frames (e.g., preface)
    def record_bytes_sent(count : Int32) : Nil
      @mutex.synchronize do
        @bytes_sent += count
        @last_activity_at = Time.utc
      end
    end

    def record_bytes_received(count : Int32) : Nil
      @mutex.synchronize do
        @bytes_received += count
        @last_activity_at = Time.utc
      end
    end

    # Get connection uptime
    def uptime : Time::Span
      Time.utc - @started_at
    end

    # Get time since last activity
    def idle_time : Time::Span
      Time.utc - @last_activity_at
    end

    # Get comprehensive metrics snapshot
    def snapshot : NamedTuple(
      started_at: Time,
      uptime_seconds: Float64,
      idle_seconds: Float64,
      streams: NamedTuple(
        created: UInt64,
        closed: UInt64,
        current: Int32,
        max_concurrent: Int32),
      bytes: NamedTuple(
        sent: UInt64,
        received: UInt64),
      frames: NamedTuple(
        sent: NamedTuple(
          total: UInt64,
          data: UInt64,
          headers: UInt64,
          priority: UInt64,
          rst_stream: UInt64,
          settings: UInt64,
          push_promise: UInt64,
          ping: UInt64,
          goaway: UInt64,
          window_update: UInt64,
          continuation: UInt64),
        received: NamedTuple(
          total: UInt64,
          data: UInt64,
          headers: UInt64,
          priority: UInt64,
          rst_stream: UInt64,
          settings: UInt64,
          push_promise: UInt64,
          ping: UInt64,
          goaway: UInt64,
          window_update: UInt64,
          continuation: UInt64)),
      errors: NamedTuple(
        sent: NamedTuple(
          total: UInt64,
          protocol: UInt64,
          internal: UInt64,
          flow_control: UInt64,
          settings_timeout: UInt64,
          stream_closed: UInt64,
          frame_size: UInt64,
          refused_stream: UInt64,
          cancel: UInt64,
          compression: UInt64,
          connect: UInt64,
          enhance_your_calm: UInt64,
          inadequate_security: UInt64,
          http_1_1_required: UInt64),
        received: NamedTuple(
          total: UInt64,
          protocol: UInt64,
          internal: UInt64,
          flow_control: UInt64,
          settings_timeout: UInt64,
          stream_closed: UInt64,
          frame_size: UInt64,
          refused_stream: UInt64,
          cancel: UInt64,
          compression: UInt64,
          connect: UInt64,
          enhance_your_calm: UInt64,
          inadequate_security: UInt64,
          http_1_1_required: UInt64)),
      flow_control: NamedTuple(
        stalls: UInt64,
        window_updates_sent: UInt64,
        window_updates_received: UInt64),
      state: NamedTuple(
        goaway_sent: Bool,
        goaway_received: Bool))
      @mutex.synchronize do
        {
          started_at:     @started_at,
          uptime_seconds: uptime.total_seconds,
          idle_seconds:   idle_time.total_seconds,
          streams:        {
            created:        @streams_created,
            closed:         @streams_closed,
            current:        @current_streams,
            max_concurrent: @max_concurrent_streams,
          },
          bytes: {
            sent:     @bytes_sent,
            received: @bytes_received,
          },
          frames: {
            sent: {
              total:         @frames_sent.total,
              data:          @frames_sent.data_frames,
              headers:       @frames_sent.headers_frames,
              priority:      @frames_sent.priority_frames,
              rst_stream:    @frames_sent.rst_stream_frames,
              settings:      @frames_sent.settings_frames,
              push_promise:  @frames_sent.push_promise_frames,
              ping:          @frames_sent.ping_frames,
              goaway:        @frames_sent.goaway_frames,
              window_update: @frames_sent.window_update_frames,
              continuation:  @frames_sent.continuation_frames,
            },
            received: {
              total:         @frames_received.total,
              data:          @frames_received.data_frames,
              headers:       @frames_received.headers_frames,
              priority:      @frames_received.priority_frames,
              rst_stream:    @frames_received.rst_stream_frames,
              settings:      @frames_received.settings_frames,
              push_promise:  @frames_received.push_promise_frames,
              ping:          @frames_received.ping_frames,
              goaway:        @frames_received.goaway_frames,
              window_update: @frames_received.window_update_frames,
              continuation:  @frames_received.continuation_frames,
            },
          },
          errors: {
            sent: {
              total:               @errors_sent.total,
              protocol:            @errors_sent.protocol_errors,
              internal:            @errors_sent.internal_errors,
              flow_control:        @errors_sent.flow_control_errors,
              settings_timeout:    @errors_sent.settings_timeout_errors,
              stream_closed:       @errors_sent.stream_closed_errors,
              frame_size:          @errors_sent.frame_size_errors,
              refused_stream:      @errors_sent.refused_stream_errors,
              cancel:              @errors_sent.cancel_errors,
              compression:         @errors_sent.compression_errors,
              connect:             @errors_sent.connect_errors,
              enhance_your_calm:   @errors_sent.enhance_your_calm_errors,
              inadequate_security: @errors_sent.inadequate_security_errors,
              http_1_1_required:   @errors_sent.http_1_1_required_errors,
            },
            received: {
              total:               @errors_received.total,
              protocol:            @errors_received.protocol_errors,
              internal:            @errors_received.internal_errors,
              flow_control:        @errors_received.flow_control_errors,
              settings_timeout:    @errors_received.settings_timeout_errors,
              stream_closed:       @errors_received.stream_closed_errors,
              frame_size:          @errors_received.frame_size_errors,
              refused_stream:      @errors_received.refused_stream_errors,
              cancel:              @errors_received.cancel_errors,
              compression:         @errors_received.compression_errors,
              connect:             @errors_received.connect_errors,
              enhance_your_calm:   @errors_received.enhance_your_calm_errors,
              inadequate_security: @errors_received.inadequate_security_errors,
              http_1_1_required:   @errors_received.http_1_1_required_errors,
            },
          },
          flow_control: {
            stalls:                  @flow_control_stalls,
            window_updates_sent:     @window_updates_sent,
            window_updates_received: @window_updates_received,
          },
          state: {
            goaway_sent:     @goaway_sent,
            goaway_received: @goaway_received,
          },
        }
      end
    end
  end
end
