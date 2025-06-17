require "./frames"
require "./hpack"
require "./security"
require "./stream"

module HT2
  class Connection
    alias HeaderCallback = Proc(Stream, Array(Tuple(String, String)), Bool, Nil)
    alias DataCallback = Proc(Stream, Bytes, Bool, Nil)

    getter socket : IO
    getter? is_server : Bool
    getter streams : Hash(UInt32, Stream)
    getter local_settings : SettingsFrame::Settings
    getter remote_settings : SettingsFrame::Settings
    getter hpack_encoder : HPACK::Encoder
    getter hpack_decoder : HPACK::Decoder
    getter window_size : Int64
    getter last_stream_id : UInt32
    getter? goaway_sent : Bool
    getter? goaway_received : Bool

    property on_headers : HeaderCallback?
    property on_data : DataCallback?

    # Test-only accessors
    {% if env("CRYSTAL_SPEC") %}
      property continuation_headers : IO::Memory
      property continuation_stream_id : UInt32?
      property total_streams_count : UInt32
      property ping_handlers : Hash(Bytes, Channel(Nil))
      property ping_rate_limiter : Security::RateLimiter

      def test_handle_continuation_frame(frame : ContinuationFrame) : Nil
        handle_continuation_frame(frame)
      end

      def test_handle_window_update_frame(frame : WindowUpdateFrame) : Nil
        handle_window_update_frame(frame)
      end

      def test_get_or_create_stream(stream_id : UInt32) : Stream
        get_or_create_stream(stream_id)
      end

      def test_handle_ping_frame(frame : PingFrame) : Nil
        handle_ping_frame(frame)
      end

      def test_handle_rst_stream_frame(frame : RstStreamFrame) : Nil
        handle_rst_stream_frame(frame)
      end

      def test_handle_priority_frame(frame : PriorityFrame) : Nil
        handle_priority_frame(frame)
      end
    {% end %}

    def initialize(@socket : IO, @is_server : Bool = true)
      @streams = Hash(UInt32, Stream).new
      @local_settings = default_settings
      @remote_settings = default_settings
      @hpack_encoder = HPACK::Encoder.new(@local_settings[SettingsParameter::HEADER_TABLE_SIZE])
      @hpack_decoder = HPACK::Decoder.new(
        @remote_settings[SettingsParameter::HEADER_TABLE_SIZE],
        @local_settings[SettingsParameter::MAX_HEADER_LIST_SIZE]
      )
      @window_size = DEFAULT_INITIAL_WINDOW_SIZE.to_i64
      @last_stream_id = @is_server ? 0_u32 : 1_u32
      @goaway_sent = false
      @goaway_received = false
      @read_buffer = Bytes.new(16_384)
      @frame_buffer = IO::Memory.new
      @continuation_stream_id = nil
      @continuation_headers = IO::Memory.new
      @continuation_end_stream = false
      @continuation_frame_count = 0_u32
      @ping_handlers = Hash(Bytes, Channel(Nil)).new
      @settings_ack_channel = Channel(Nil).new
      @pending_settings = [] of Channel(Nil)
      @closed = false
      @write_mutex = Mutex.new
      @total_streams_count = 0_u32

      # Rate limiters for flood protection
      @settings_rate_limiter = Security::RateLimiter.new(Security::MAX_SETTINGS_PER_SECOND)
      @ping_rate_limiter = Security::RateLimiter.new(Security::MAX_PING_PER_SECOND)
      @rst_rate_limiter = Security::RateLimiter.new(Security::MAX_RST_PER_SECOND)
      @priority_rate_limiter = Security::RateLimiter.new(Security::MAX_PRIORITY_PER_SECOND)
    end

    def start : Nil
      if @is_server
        # Server waits for client preface
        read_client_preface
      else
        # Client sends preface
        send_client_preface
      end

      # Send initial settings
      send_frame(SettingsFrame.new(settings: @local_settings))

      # Start reading frames
      spawn { read_loop }

      # Wait for SETTINGS acknowledgment with timeout
      spawn do
        select
        when @settings_ack_channel.receive
          # Settings acknowledged, continue
        when timeout(HT2::SETTINGS_ACK_TIMEOUT)
          # Timeout waiting for SETTINGS ACK
          unless @closed
            send_goaway(ErrorCode::SETTINGS_TIMEOUT, "Settings acknowledgment timeout")
            close
          end
        end
      end
    rescue ex : IO::Error
      # Socket was closed during handshake
      close
      raise ex
    end

    def close : Nil
      return if @closed
      @closed = true

      unless @goaway_sent
        begin
          send_goaway(ErrorCode::NO_ERROR)
        rescue ex : IO::Error
          # Socket already closed, ignore
        end
      end

      begin
        @socket.close
      rescue ex : IO::Error
        # Already closed, ignore
      end
    end

    def create_stream : Stream
      # Check concurrent stream limit
      active_streams = @streams.count { |_, stream| !stream.closed? }
      max_streams = @remote_settings[SettingsParameter::MAX_CONCURRENT_STREAMS]

      if active_streams >= max_streams
        raise ConnectionError.new(ErrorCode::REFUSED_STREAM, "Maximum concurrent streams (#{max_streams}) reached")
      end

      stream_id = next_stream_id
      stream = Stream.new(stream_id, self)
      @streams[stream_id] = stream
      @total_streams_count += 1
      stream
    end

    def send_frame(frame : Frame) : Nil
      @write_mutex.synchronize do
        begin
          @socket.write(frame.to_bytes)
          @socket.flush
        rescue ex : IO::Error
          # Socket closed, ignore write errors
          @closed = true
          raise ex
        end
      end
    end

    def send_goaway(error_code : ErrorCode, debug_data : String = "") : Nil
      return if @goaway_sent

      @goaway_sent = true
      frame = GoAwayFrame.new(@last_stream_id, error_code, debug_data.to_slice)
      send_frame(frame)
    end

    def ping(data : Bytes? = nil) : Channel(Nil)
      data ||= Random::Secure.random_bytes(8)
      channel = Channel(Nil).new
      @ping_handlers[data] = channel

      frame = PingFrame.new(data)
      send_frame(frame)

      channel
    end

    def update_settings(settings : SettingsFrame::Settings) : Channel(Nil)
      @local_settings.merge!(settings)

      # Update HPACK table size if changed
      if table_size = settings[SettingsParameter::HEADER_TABLE_SIZE]?
        @hpack_encoder.max_table_size = table_size
      end

      # Update max header list size if changed
      if max_headers = settings[SettingsParameter::MAX_HEADER_LIST_SIZE]?
        @hpack_decoder.max_headers_size = max_headers
      end

      # Create a new channel for this specific settings update
      ack_channel = Channel(Nil).new
      @pending_settings << ack_channel

      frame = SettingsFrame.new(settings: settings)
      send_frame(frame)

      # Add timeout handling
      spawn do
        select
        when ack_channel.receive
          # Settings acknowledged
        when timeout(HT2::SETTINGS_ACK_TIMEOUT)
          # Timeout waiting for SETTINGS ACK
          @pending_settings.delete(ack_channel)
          unless @closed
            send_goaway(ErrorCode::SETTINGS_TIMEOUT, "Settings acknowledgment timeout")
            close
          end
        end
      end

      ack_channel
    end

    def consume_window(size : Int32) : Nil
      @window_size -= size
    end

    private def read_client_preface
      preface = Bytes.new(CONNECTION_PREFACE.bytesize)
      begin
        @socket.read_fully(preface)
      rescue ex : IO::Error
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Failed to read client preface: #{ex.message}")
      end

      if String.new(preface) != CONNECTION_PREFACE
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid client preface")
      end
    end

    private def send_client_preface
      @socket.write(CONNECTION_PREFACE.to_slice)
      @socket.flush
    end

    private def read_loop
      loop do
        begin
          # Read frame header
          header_bytes = Bytes.new(Frame::HEADER_SIZE)
          @socket.read_fully(header_bytes)

          length, _, _, stream_id = Frame.parse_header(header_bytes)

          # Validate frame size against negotiated MAX_FRAME_SIZE
          max_frame_size = @remote_settings[SettingsParameter::MAX_FRAME_SIZE]
          Security.validate_frame_size(length, max_frame_size)

          # Read frame payload
          payload = Bytes.new(length)
          @socket.read_fully(payload) if length > 0

          # Combine header and payload
          full_frame = Bytes.new(Frame::HEADER_SIZE + length)
          header_bytes.copy_to(full_frame)
          payload.copy_to((full_frame + Frame::HEADER_SIZE).to_unsafe, length) if length > 0

          # Parse and handle frame
          frame = Frame.parse(full_frame)
          handle_frame(frame)
        rescue ex : IO::Error
          break
        rescue ex : ConnectionError
          send_goaway(ex.code, ex.message || "")
          # Allow time for GOAWAY to be sent
          sleep 0.1.seconds
          break
        rescue ex : StreamError
          stream = @streams[ex.stream_id]?
          stream.try(&.send_rst_stream(ex.code))
          # Allow time for RST_STREAM to be sent
          sleep 0.05.seconds
        end
      end
    ensure
      close
    end

    private def handle_frame(frame : Frame)
      case frame
      when DataFrame
        handle_data_frame(frame)
      when HeadersFrame
        handle_headers_frame(frame)
      when PriorityFrame
        handle_priority_frame(frame)
      when RstStreamFrame
        handle_rst_stream_frame(frame)
      when SettingsFrame
        handle_settings_frame(frame)
      when PushPromiseFrame
        handle_push_promise_frame(frame)
      when PingFrame
        handle_ping_frame(frame)
      when GoAwayFrame
        handle_goaway_frame(frame)
      when WindowUpdateFrame
        handle_window_update_frame(frame)
      when ContinuationFrame
        handle_continuation_frame(frame)
      end
    end

    private def handle_data_frame(frame : DataFrame)
      stream = get_stream(frame.stream_id)

      # Update flow control windows
      stream.receive_data(frame.data, frame.flags.end_stream?)

      # Send window update if needed
      if frame.data.size > 0
        threshold = @local_settings[SettingsParameter::INITIAL_WINDOW_SIZE] / 2

        if @window_size < threshold
          increment = @local_settings[SettingsParameter::INITIAL_WINDOW_SIZE] - @window_size
          send_frame(WindowUpdateFrame.new(0, increment.to_u32))
          @window_size += increment
        end
      end

      # Notify callback
      if callback = @on_data
        callback.call(stream, frame.data, frame.flags.end_stream?)
      end
    end

    private def handle_headers_frame(frame : HeadersFrame)
      if @continuation_stream_id
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "HEADERS while expecting CONTINUATION")
      end

      stream = get_or_create_stream(frame.stream_id)

      if priority = frame.priority
        stream.receive_priority(priority)
      end

      if frame.flags.end_headers?
        # Complete headers
        begin
          headers = @hpack_decoder.decode(frame.header_block)
          stream.receive_headers(headers, frame.flags.end_stream?)

          if callback = @on_headers
            callback.call(stream, headers, frame.flags.end_stream?)
          end
        rescue ex : HPACK::DecompressionError
          # HPACK decompression failed - protocol error
          raise StreamError.new(frame.stream_id, ErrorCode::COMPRESSION_ERROR, ex.message)
        end
      else
        # Expecting CONTINUATION frames
        @continuation_stream_id = frame.stream_id
        @continuation_headers.write(frame.header_block)
        @continuation_end_stream = frame.flags.end_stream?
        @continuation_frame_count = 0_u32
      end
    end

    private def handle_continuation_frame(frame : ContinuationFrame)
      if @continuation_stream_id.nil?
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "CONTINUATION without HEADERS")
      end

      if @continuation_stream_id != frame.stream_id
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "CONTINUATION stream mismatch")
      end

      # Check continuation frame count limit
      @continuation_frame_count += 1
      if @continuation_frame_count > Security::MAX_CONTINUATION_FRAMES
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR,
          "CONTINUATION frame count exceeds limit: #{@continuation_frame_count}")
      end

      # Check continuation size limit
      if @continuation_headers.size + frame.header_block.size > Security::MAX_CONTINUATION_SIZE
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "CONTINUATION frames exceed size limit")
      end

      @continuation_headers.write(frame.header_block)

      if frame.flags.end_headers?
        stream = get_stream(frame.stream_id)
        begin
          headers = @hpack_decoder.decode(@continuation_headers.to_slice)

          # Use tracked END_STREAM flag from original HEADERS frame
          end_stream = @continuation_end_stream

          stream.receive_headers(headers, end_stream)

          if callback = @on_headers
            callback.call(stream, headers, end_stream)
          end
        rescue ex : HPACK::DecompressionError
          # HPACK decompression failed - protocol error
          raise StreamError.new(frame.stream_id, ErrorCode::COMPRESSION_ERROR, ex.message)
        end

        @continuation_stream_id = nil
        @continuation_headers.clear
        @continuation_frame_count = 0_u32
      end
    end

    private def handle_priority_frame(frame : PriorityFrame)
      unless @priority_rate_limiter.check
        raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "PRIORITY flood detected")
      end

      stream = get_or_create_stream(frame.stream_id)
      stream.receive_priority(frame.priority)
    end

    private def handle_rst_stream_frame(frame : RstStreamFrame)
      unless @rst_rate_limiter.check
        raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "RST_STREAM flood detected")
      end

      stream = @streams[frame.stream_id]?
      return unless stream

      stream.receive_rst_stream
      @streams.delete(frame.stream_id)
    end

    private def handle_settings_frame(frame : SettingsFrame)
      if frame.flags.ack?
        # Settings acknowledged - notify the oldest pending settings
        @settings_ack_channel.send(nil)

        # Also notify any pending update_settings calls
        if channel = @pending_settings.shift?
          channel.send(nil)
        end
      else
        # Rate limit SETTINGS frames
        unless @settings_rate_limiter.check
          raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "SETTINGS flood detected")
        end
        # Apply remote settings
        frame.settings.each do |param, value|
          @remote_settings[param] = value

          case param
          when SettingsParameter::HEADER_TABLE_SIZE
            @hpack_decoder.max_dynamic_table_size = value
          when SettingsParameter::INITIAL_WINDOW_SIZE
            # Update all stream windows
            diff = value.to_i64 - @remote_settings[SettingsParameter::INITIAL_WINDOW_SIZE].to_i64
            @streams.each_value { |stream| stream.window_size += diff }
          end
        end

        # Send ACK
        send_frame(SettingsFrame.new(FrameFlags::ACK))
      end
    end

    private def handle_push_promise_frame(frame : PushPromiseFrame)
      if @is_server
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Server received PUSH_PROMISE")
      end

      # Push promises not implemented for now
      raise ConnectionError.new(ErrorCode::REFUSED_STREAM, "Push promises not supported")
    end

    private def handle_ping_frame(frame : PingFrame)
      if frame.flags.ack?
        # Ping response
        if channel = @ping_handlers.delete(frame.opaque_data)
          channel.send(nil)
        end
      else
        # Rate limit PING frames
        unless @ping_rate_limiter.check
          raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "PING flood detected")
        end

        # Limit ping queue size
        if @ping_handlers.size >= Security::MAX_PING_QUEUE_SIZE
          # Clear oldest ping handler
          @ping_handlers.shift
        end

        # Send ping ACK
        send_frame(PingFrame.new(frame.opaque_data, FrameFlags::ACK))
      end
    end

    private def handle_goaway_frame(frame : GoAwayFrame)
      @goaway_received = true
      @last_stream_id = frame.last_stream_id

      # Close streams with ID > last_stream_id
      @streams.each do |id, stream|
        if id > frame.last_stream_id
          @streams.delete(id)
        end
      end
    end

    private def handle_window_update_frame(frame : WindowUpdateFrame)
      if frame.stream_id == 0
        # Connection window update with checked arithmetic
        increment = frame.window_size_increment.to_i64

        # Check for zero increment
        if increment == 0
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Window increment cannot be zero")
        end

        new_window = Security.checked_add(@window_size, increment)

        if new_window > Security::MAX_WINDOW_SIZE
          raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "Connection window overflow")
        end

        @window_size = new_window
      else
        # Stream window update
        stream = get_stream(frame.stream_id)
        stream.receive_window_update(frame.window_size_increment)
      end
    end

    private def get_stream(stream_id : UInt32) : Stream
      @streams[stream_id] || raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Unknown stream #{stream_id}")
    end

    private def get_or_create_stream(stream_id : UInt32) : Stream
      @streams[stream_id] ||= begin
        if stream_id <= @last_stream_id
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Stream ID not increasing")
        end

        # Check concurrent stream limit
        active_streams = @streams.count { |_, stream| !stream.closed? }
        max_streams = @local_settings[SettingsParameter::MAX_CONCURRENT_STREAMS]

        if active_streams >= max_streams
          raise ConnectionError.new(ErrorCode::REFUSED_STREAM, "Maximum concurrent streams (#{max_streams}) reached")
        end

        # Check total stream limit
        if @total_streams_count >= Security::MAX_TOTAL_STREAMS
          raise ConnectionError.new(ErrorCode::REFUSED_STREAM, "Total stream limit reached")
        end

        @last_stream_id = stream_id
        @total_streams_count += 1
        Stream.new(stream_id, self, StreamState::IDLE)
      end
    end

    private def next_stream_id : UInt32
      @last_stream_id += 2
      @last_stream_id
    end

    private def default_settings : SettingsFrame::Settings
      settings = SettingsFrame::Settings.new
      settings[SettingsParameter::HEADER_TABLE_SIZE] = DEFAULT_HEADER_TABLE_SIZE
      settings[SettingsParameter::MAX_CONCURRENT_STREAMS] = DEFAULT_MAX_CONCURRENT_STREAMS
      settings[SettingsParameter::INITIAL_WINDOW_SIZE] = DEFAULT_INITIAL_WINDOW_SIZE
      settings[SettingsParameter::MAX_FRAME_SIZE] = DEFAULT_MAX_FRAME_SIZE
      settings[SettingsParameter::MAX_HEADER_LIST_SIZE] = DEFAULT_MAX_HEADER_LIST_SIZE
      settings[SettingsParameter::ENABLE_PUSH] = 0_u32 # Disable push
      settings
    end
  end
end
