require "./adaptive_buffer_manager"
require "./adaptive_flow_control"
require "./backpressure"
require "./buffer_pool"
require "./connection_metrics"
require "./debug_mode"
require "./frame_cache"
require "./frames"
require "./hpack"
require "./header_validator"
require "./multi_frame_writer"
require "./performance_metrics"
require "./rapid_reset_protection"
require "./security"
require "./stream"
require "./stream_lifecycle_tracer"
require "./vectored_io"

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
    getter applied_settings : SettingsFrame::Settings
    getter backpressure_manager : BackpressureManager
    getter adaptive_buffer_manager : AdaptiveBufferManager
    getter buffer_pool : BufferPool
    getter frame_cache : FrameCache
    getter metrics : ConnectionMetrics
    getter performance_metrics : PerformanceMetrics
    getter stream_lifecycle_tracer : StreamLifecycleTracer
    getter? closed : Bool

    property on_headers : HeaderCallback?
    property on_data : DataCallback?

    def initialize(@socket : IO, @is_server : Bool = true, client_ip : String? = nil)
      @streams = Hash(UInt32, Stream).new
      @local_settings = default_settings
      @remote_settings = default_settings
      @applied_settings = SettingsFrame::Settings.new
      @hpack_encoder = HPACK::Encoder.new(@local_settings[SettingsParameter::HEADER_TABLE_SIZE])
      @hpack_decoder = HPACK::Decoder.new(
        @remote_settings[SettingsParameter::HEADER_TABLE_SIZE],
        @local_settings[SettingsParameter::MAX_HEADER_LIST_SIZE]
      )
      @window_size = DEFAULT_INITIAL_WINDOW_SIZE.to_i64
      @last_stream_id = @is_server ? 0_u32 : 1_u32
      @goaway_sent = false
      @goaway_received = false
      # Adaptive buffer management
      @adaptive_buffer_manager = AdaptiveBufferManager.new
      @read_buffer = Bytes.new(@adaptive_buffer_manager.recommended_read_buffer_size)
      @frame_buffer = IO::Memory.new
      @continuation_stream_id = nil
      @continuation_headers = IO::Memory.new
      @continuation_end_stream = false
      @continuation_frame_count = 0_u32
      @continuation_started_at = nil.as(Time?)
      @ping_handlers = Hash(Bytes, Channel(Nil)).new
      @settings_ack_channel = Channel(Nil).new
      @pending_settings = [] of Channel(Nil)
      @closed = false
      @write_mutex = Mutex.new
      @total_streams_count = 0_u32

      # Track recently closed streams to properly reject frames
      @closed_streams = Set(UInt32).new
      @closed_stream_limit = 100_u32 # Keep track of last 100 closed streams

      # Rate limiters for flood protection
      @settings_rate_limiter = Security::RateLimiter.new(Security::MAX_SETTINGS_PER_SECOND)
      @ping_rate_limiter = Security::RateLimiter.new(Security::MAX_PING_PER_SECOND)
      @rst_rate_limiter = Security::RateLimiter.new(Security::MAX_RST_PER_SECOND)
      @priority_rate_limiter = Security::RateLimiter.new(Security::MAX_PRIORITY_PER_SECOND)

      # Adaptive flow control
      @flow_controller = AdaptiveFlowControl.new(
        @local_settings[SettingsParameter::INITIAL_WINDOW_SIZE].to_i64,
        AdaptiveFlowControl::Strategy::DYNAMIC
      )

      # Rapid reset protection
      @rapid_reset_protection = RapidResetProtection.new
      # Use client IP if provided, otherwise fall back to object-based ID
      @connection_id = client_ip || "#{@socket.class.name}:#{@socket.object_id}"

      # Backpressure management
      @backpressure_manager = BackpressureManager.new

      # Buffer pool for frame operations
      @buffer_pool = BufferPool.new

      # Frame cache for common frames
      @frame_cache = FrameCache.new

      # Connection metrics tracking
      @metrics = ConnectionMetrics.new
      @performance_metrics = PerformanceMetrics.new

      # Stream lifecycle tracing (disabled by default)
      @stream_lifecycle_tracer = StreamLifecycleTracer.new(false)
    end

    def start : Nil
      Log.debug { "Connection.start called, is_server=#{@is_server}" }

      if @is_server
        # Server waits for client preface
        Log.debug { "Reading client preface..." }
        read_client_preface
        Log.debug { "Client preface read successfully" }
      else
        # Client sends preface
        send_client_preface
      end

      Log.debug { "Starting without preface..." }
      start_without_preface
      Log.debug { "Connection started successfully" }
    rescue ex : IO::Error
      # Log the error for debugging
      Log.debug { "Connection start failed: #{ex.message}" }
      close
      raise ex
    end

    # Start connection without reading/sending preface (used for h2c upgrade)
    def start_without_preface : Nil
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
            begin
              send_goaway(ErrorCode::SETTINGS_TIMEOUT, "Settings acknowledgment timeout")
              close
            rescue IO::Error
              # Connection already closed, ignore
            end
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

      unless @goaway_sent
        begin
          send_goaway(ErrorCode::NO_ERROR)
        rescue ex : IO::Error
          # Socket already closed, ignore
          Log.debug { "Failed to send GOAWAY on close: #{ex.message}" }
        end
      end

      @closed = true

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
      stream = Stream.new(self, stream_id)
      @streams[stream_id] = stream
      @total_streams_count += 1

      # Track metrics
      @metrics.record_stream_created(stream_id)
      @performance_metrics.record_stream_created(stream_id)
      @stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::CREATED,
        stream_id,
        "Stream created by client"
      )

      stream
    end

    # Create a stream with a specific ID (used for h2c upgrade)
    def create_stream(stream_id : UInt32) : Stream
      # Check concurrent stream limit
      active_streams = @streams.count { |_, stream| !stream.closed? }
      max_streams = @remote_settings[SettingsParameter::MAX_CONCURRENT_STREAMS]

      if active_streams >= max_streams
        raise ConnectionError.new(ErrorCode::REFUSED_STREAM, "Maximum concurrent streams (#{max_streams}) reached")
      end

      # Validate stream ID
      if @is_server && stream_id.even?
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid stream ID for server")
      elsif !@is_server && stream_id.odd?
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid stream ID for client")
      end

      # Update last stream ID if needed
      if stream_id > @last_stream_id
        @last_stream_id = stream_id
      end

      stream = Stream.new(self, stream_id)
      @streams[stream_id] = stream
      @total_streams_count += 1

      # Track metrics
      @metrics.record_stream_created(stream_id)
      @performance_metrics.record_stream_created(stream_id)
      @stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::CREATED,
        stream_id,
        "Stream created for h2c upgrade"
      )

      stream
    end

    def send_frame(frame : Frame) : Nil
      # Log outbound frame if debug mode is enabled
      DebugMode.log_frame(@connection_id, DebugMode::Direction::Outbound, frame)

      # For DATA frames without padding, use zero-copy path
      if frame.is_a?(DataFrame) && !frame.flags.padded?
        send_frame_zero_copy(frame.as(DataFrame))
        return
      end

      # Check for cached frames
      is_cached = false
      frame_bytes = case frame
                    when SettingsFrame
                      if frame.as(SettingsFrame).flags.ack?
                        cached = @frame_cache.get("settings_ack")
                        is_cached = !cached.nil?
                        cached
                      end
                    when PingFrame
                      ping_frame = frame.as(PingFrame)
                      if ping_frame.flags.ack? && ping_frame.opaque_data.all? { |byte| byte == 0 }
                        cached = @frame_cache.get("ping_ack_0")
                        is_cached = !cached.nil?
                        cached
                      end
                    end

      # Use buffer pool if not cached
      frame_bytes ||= frame.to_bytes(@buffer_pool)
      stream_id = frame.stream_id > 0 ? frame.stream_id : nil

      # Track write pressure before sending
      @backpressure_manager.track_write(frame_bytes.size.to_i64, stream_id)

      # Wait if backpressure is high
      unless @backpressure_manager.wait_for_capacity
        @backpressure_manager.complete_write(frame_bytes.size.to_i64, stream_id)
        @buffer_pool.release(frame_bytes) unless is_cached
        raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "Write buffer full")
      end

      @write_mutex.synchronize do
        begin
          @socket.write(frame_bytes)
          @socket.flush

          # Track metrics
          @metrics.record_frame_sent(frame)
          @metrics.record_bytes_sent(frame_bytes.size)

          # Record throughput for data frames
          if frame.is_a?(DataFrame) && frame.data.size > 0
            @performance_metrics.record_bytes_sent(frame.data.size.to_u64)
          end

          # Mark write as complete
          @backpressure_manager.complete_write(frame_bytes.size.to_i64, stream_id)

          # Release buffer back to pool if not from cache
          @buffer_pool.release(frame_bytes) unless is_cached
        rescue ex : IO::Error
          # Socket closed, ignore write errors
          @closed = true
          @buffer_pool.release(frame_bytes) unless is_cached
          raise ex
        end
      end
    end

    # Zero-copy send for DATA frames without padding
    private def send_frame_zero_copy(frame : DataFrame) : Nil
      # Calculate frame size for backpressure tracking
      frame_size = Frame::HEADER_SIZE + frame.data.size
      stream_id = frame.stream_id

      # Track write pressure before sending
      @backpressure_manager.track_write(frame_size.to_i64, stream_id)

      # Wait if backpressure is high
      unless @backpressure_manager.wait_for_capacity
        @backpressure_manager.complete_write(frame_size.to_i64, stream_id)
        raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "Write buffer full")
      end

      @write_mutex.synchronize do
        begin
          # Use zero-copy write
          frame.write_to(@socket)
          @socket.flush

          # Track metrics
          @metrics.record_frame_sent(frame)
          @metrics.record_bytes_sent(frame_size)

          # Record throughput for data frames
          if frame.is_a?(DataFrame) && frame.data.size > 0
            @performance_metrics.record_bytes_sent(frame.data.size.to_u64)
          end

          # Mark write as complete
          @backpressure_manager.complete_write(frame_size.to_i64, stream_id)
        rescue ex : IO::Error
          # Socket closed, ignore write errors
          @closed = true
          raise ex
        end
      end
    end

    # Send multiple frames efficiently using batched I/O
    def send_frames(frames : Array(Frame)) : Nil
      return if frames.empty?

      writer = MultiFrameWriter.new(@buffer_pool, @adaptive_buffer_manager)
      writer.add_frames(frames)

      @write_mutex.synchronize do
        writer.flush_to(@socket)
      end

      writer.release
    end

    # Send prioritized frames in priority order
    def send_prioritized_frames(frames : Array(MultiFrameWriter::PrioritizedFrame)) : Nil
      return if frames.empty?

      writer = MultiFrameWriter.new(@buffer_pool, @adaptive_buffer_manager)
      writer.add_prioritized_frames(frames)

      @write_mutex.synchronize do
        writer.flush_to(@socket)
      end

      writer.release
    end

    # Send multiple DATA frames from the same stream efficiently
    def send_data_frames(stream_id : UInt32, data_chunks : Array(Bytes), end_stream : Bool = false) : Nil
      return if data_chunks.empty?

      # Calculate total size for flow control
      total_size = data_chunks.sum(&.size)
      stream = @streams[stream_id]?
      raise StreamError.new(stream_id, ErrorCode::STREAM_CLOSED, "Stream not found") unless stream

      # Check flow control
      if total_size > stream.send_window_size
        raise StreamError.new(stream_id, ErrorCode::FLOW_CONTROL_ERROR, "Data size exceeds stream window")
      end

      if total_size > @window_size
        raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "Data size exceeds connection window")
      end

      # Track write pressure
      @backpressure_manager.track_write(total_size.to_i64, stream_id)

      # Wait if backpressure is high
      unless @backpressure_manager.wait_for_capacity
        @backpressure_manager.complete_write(total_size.to_i64, stream_id)
        raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "Write buffer full")
      end

      @write_mutex.synchronize do
        begin
          MultiFrameWriter.write_data_frames(@socket, stream_id, data_chunks, end_stream)

          # Update flow control windows
          stream.send_window_size -= total_size
          @window_size -= total_size

          # Mark write as complete
          @backpressure_manager.complete_write(total_size.to_i64, stream_id)
        rescue ex : IO::Error
          @closed = true
          raise ex
        end
      end
    end

    # Send multiple frames using direct vectored I/O without buffering
    # This is most efficient when frames are already serialized or when
    # sending many small frames that would benefit from atomic writes
    def send_frames_vectored(frames : Array(Frame)) : Nil
      return if frames.empty?
      return send_frames(frames) unless @socket.is_a?(IO::FileDescriptor)

      # Log frames if debug mode is enabled
      frames.each do |frame|
        DebugMode.log_frame(@connection_id, DebugMode::Direction::Outbound, frame)
      end

      @write_mutex.synchronize do
        VectoredIO.write_frames(@socket.as(IO::FileDescriptor), frames, @buffer_pool)
      end
    end

    def send_goaway(error_code : ErrorCode, debug_data : String = "") : Nil
      return if @goaway_sent || @closed

      @goaway_sent = true
      frame = GoAwayFrame.new(@last_stream_id, error_code, debug_data.to_slice)
      begin
        send_frame(frame)
      rescue ex : IO::Error
        # Socket already closed, ignore
        Log.debug { "Failed to send GOAWAY: #{ex.message}" }
      end
    end

    def update_settings(settings : SettingsFrame::Settings) : Channel(Nil)
      validate_all_settings(settings)
      apply_local_settings(settings)
      send_settings_with_ack_timeout(settings)
    end

    private def validate_all_settings(settings : SettingsFrame::Settings) : Nil
      settings.each do |param, value|
        validate_setting(param, value)
      end
    end

    private def apply_local_settings(settings : SettingsFrame::Settings) : Nil
      settings.each do |param, value|
        @local_settings[param] = value
        apply_local_setting(param, value)
      end
    end

    private def apply_local_setting(param : SettingsParameter, value : UInt32) : Nil
      case param
      when SettingsParameter::HEADER_TABLE_SIZE
        @hpack_encoder.update_dynamic_table_size(value)
      when SettingsParameter::MAX_HEADER_LIST_SIZE
        @hpack_decoder.max_headers_size = value
      when SettingsParameter::INITIAL_WINDOW_SIZE
        # This affects new streams only, existing streams keep their windows
      end
    end

    private def send_settings_with_ack_timeout(settings : SettingsFrame::Settings) : Channel(Nil)
      ack_channel = Channel(Nil).new
      @pending_settings << ack_channel

      send_frame(SettingsFrame.new(settings: settings))

      spawn { wait_for_settings_ack(ack_channel) }

      ack_channel
    end

    private def wait_for_settings_ack(ack_channel : Channel(Nil)) : Nil
      select
      when ack_channel.receive
        # ACK received
      when timeout(HT2::SETTINGS_ACK_TIMEOUT)
        @pending_settings.delete(ack_channel)
        unless @closed
          begin
            send_goaway(ErrorCode::SETTINGS_TIMEOUT, "Settings acknowledgment timeout")
            close
          rescue IO::Error
            # Connection already closed, ignore
          end
        end
      end
    end

    def ping(data : Bytes? = nil) : Channel(Nil)
      data ||= Random::Secure.random_bytes(8)
      channel = Channel(Nil).new
      @ping_handlers[data] = channel

      frame = PingFrame.new(data)
      send_frame(frame)

      channel
    end

    def consume_window(size : Int32) : Nil
      @window_size -= size
    end

    private def read_client_preface
      preface = Bytes.new(CONNECTION_PREFACE.bytesize)
      begin
        Log.debug { "Attempting to read #{CONNECTION_PREFACE.bytesize} bytes for preface" }
        @socket.read_fully(preface)
        Log.debug { "Read preface bytes: #{preface.hexstring}" }
      rescue ex : IO::Error
        Log.debug { "Failed to read preface: #{ex.class} - #{ex.message}" }
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Failed to read client preface: #{ex.message}")
      end

      preface_string = String.new(preface)
      if preface_string != CONNECTION_PREFACE
        Log.debug { "Invalid preface. Expected: #{CONNECTION_PREFACE.inspect}, Got: #{preface_string.inspect}" }
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid client preface")
      end

      # Track metrics
      @metrics.record_bytes_received(CONNECTION_PREFACE.bytesize)
      @performance_metrics.record_bytes_received(CONNECTION_PREFACE.bytesize.to_u64)
    end

    private def send_client_preface
      @socket.write(CONNECTION_PREFACE.to_slice)
      @socket.flush

      # Track metrics
      @metrics.record_bytes_sent(CONNECTION_PREFACE.bytesize)
      @performance_metrics.record_bytes_sent(CONNECTION_PREFACE.bytesize.to_u64)
    end

    private def read_loop
      Log.debug { "Read loop started for connection #{@connection_id}" }
      loop do
        begin
          # Read frame header using buffer pool
          header_bytes = @buffer_pool.acquire(Frame::HEADER_SIZE)
          Log.debug { "Reading frame header..." }
          begin
            @socket.read_fully(header_bytes)
          rescue ex : IO::Error
            Log.debug { "Failed to read frame header: #{ex.message}" }
            raise ex
          end

          length, _, _, stream_id = Frame.parse_header(header_bytes)

          # Validate frame size against negotiated MAX_FRAME_SIZE
          max_frame_size = @remote_settings[SettingsParameter::MAX_FRAME_SIZE]
          begin
            Security.validate_frame_size(length, max_frame_size)
          rescue ex : ConnectionError
            if ex.code == ErrorCode::FRAME_SIZE_ERROR
              @performance_metrics.security_events.record_frame_size_violation
            end
            raise ex
          end

          # Track frame size for adaptive buffering
          @adaptive_buffer_manager.record_frame_size(Frame::HEADER_SIZE + length)

          # Acquire buffer for full frame
          full_frame = @buffer_pool.acquire(Frame::HEADER_SIZE + length)

          # Copy header
          header_bytes.copy_to(full_frame)

          # Read payload directly into buffer
          if length > 0
            @socket.read_fully(full_frame[Frame::HEADER_SIZE, length])
          end

          # Log raw frame bytes if debug mode is enabled
          raw_frame = full_frame[0, Frame::HEADER_SIZE + length]
          DebugMode.log_raw_frame(@connection_id, DebugMode::Direction::Inbound, raw_frame)

          # Parse and handle frame
          frame = Frame.parse(full_frame[0, Frame::HEADER_SIZE + length])

          # Log parsed frame if debug mode is enabled
          DebugMode.log_frame(@connection_id, DebugMode::Direction::Inbound, frame)

          # Track metrics
          @metrics.record_frame_received(frame)
          @metrics.record_bytes_received(Frame::HEADER_SIZE + length)
          @performance_metrics.record_bytes_received((Frame::HEADER_SIZE + length).to_u64)

          handle_frame(frame)
          Log.debug { "Successfully handled frame: #{frame.class} on stream #{frame.stream_id}" }

          # Release buffers back to pool
          @buffer_pool.release(header_bytes)
          @buffer_pool.release(full_frame)

          # Check if we should continue reading
          if @closed || @goaway_sent
            Log.debug { "Connection closed or GOAWAY sent, exiting read loop" }
            break
          end

          # Periodically adapt read buffer size
          if @adaptive_buffer_manager.should_adapt?
            new_size = @adaptive_buffer_manager.recommended_read_buffer_size
            if new_size != @read_buffer.size
              @read_buffer = Bytes.new(new_size)
            end
          end
        rescue ex : IO::Error
          # Log IO errors for debugging
          Log.debug { "Read loop IO error: #{ex.class} - #{ex.message}" }
          Log.debug { "Socket closed: #{@socket.closed?}" } rescue nil
          break
        rescue ex : ConnectionError
          Log.debug { "Read loop connection error: #{ex.code} - #{ex.message}" }
          send_goaway(ex.code, ex.message || "")
          # Allow time for GOAWAY to be sent
          sleep 0.1.seconds
          break
        rescue ex : StreamError
          Log.debug { "Read loop stream error: #{ex.stream_id} - #{ex.code} - #{ex.message}" }
          stream = @streams[ex.stream_id]?
          if stream
            stream.send_rst_stream(ex.code)
          else
            # Stream doesn't exist (already closed), send RST_STREAM directly
            send_frame(RstStreamFrame.new(ex.stream_id, ex.code))
          end
          # Flush the frame immediately instead of sleeping
          @socket.flush rescue nil
        rescue ex
          Log.error { "Read loop unexpected error: #{ex.class} - #{ex.message}" }
          raise ex
        end
      end
    ensure
      Log.debug { "Read loop exiting, closing connection" }
      close
    end

    private def handle_frame(frame : Frame)
      # Check if we're expecting CONTINUATION frames
      if @continuation_stream_id && !frame.is_a?(ContinuationFrame)
        # Only CONTINUATION frames are allowed when we're in the middle of a header block
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR,
          "#{frame.class} received while expecting CONTINUATION")
      end

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
      # Check if this is a closed stream
      if is_stream_closed?(frame.stream_id)
        raise StreamError.new(frame.stream_id, ErrorCode::STREAM_CLOSED, "DATA on closed stream")
      end

      stream = get_stream(frame.stream_id)

      # Update flow control windows
      stream.receive_data(frame.data, frame.flags.end_stream?)

      # Record data received for rapid reset protection
      if frame.data.size > 0
        @rapid_reset_protection.record_data_received(frame.stream_id)
        # Record first byte for performance metrics
        @performance_metrics.record_stream_first_byte(frame.stream_id)
        # Record throughput
        @performance_metrics.record_bytes_received(frame.data.size.to_u64)
      end

      # Send window update if needed using adaptive flow control
      if frame.data.size > 0
        consumed = @local_settings[SettingsParameter::INITIAL_WINDOW_SIZE].to_i64 - @window_size

        if @flow_controller.needs_update?(@local_settings[SettingsParameter::INITIAL_WINDOW_SIZE].to_i64, @window_size)
          increment = @flow_controller.calculate_increment(@window_size, consumed)

          if increment > 0
            send_frame(WindowUpdateFrame.new(0, increment.to_u32))
            @window_size += increment
          end
        end

        # Record stall if window is exhausted
        if @window_size <= 0
          @flow_controller.record_stall
          @metrics.record_flow_control_stall
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

      # Check if this is a closed stream
      if is_stream_closed?(frame.stream_id)
        raise StreamError.new(frame.stream_id, ErrorCode::STREAM_CLOSED, "HEADERS on closed stream")
      end

      stream = get_or_create_stream(frame.stream_id)

      Log.debug do
        "HEADERS frame: stream_id=#{frame.stream_id}, flags=#{frame.flags}, " \
        "padding=#{frame.padding}, priority=#{frame.priority.inspect}, " \
        "header_block_size=#{frame.header_block.size}"
      end
      Log.debug { "Full header block hex: #{frame.header_block.hexstring}" }

      if priority = frame.priority
        stream.receive_priority(priority)
      end

      if frame.flags.end_headers?
        # Complete headers
        begin
          Log.debug { "Decoding HEADERS frame with block size: #{frame.header_block.size}" }
          Log.debug do
            "First 20 bytes of header block: " \
            "#{frame.header_block[0...20]?.try(&.hexstring) || "less than 20 bytes"}"
          end

          headers = @hpack_decoder.decode(frame.header_block)
          Log.debug { "Decoded headers before validation: #{headers.inspect}" }

          # Check if this is trailers (stream already has headers and data)
          is_trailers = !!(stream.request_headers && stream.data.size > 0)

          # Validate headers according to HTTP/2 spec
          validator = HeaderValidator.new(is_request: true, is_trailers: is_trailers)
          begin
            validated_headers = validator.validate(headers)
          rescue ex : StreamError
            # Re-raise with correct stream ID
            raise StreamError.new(frame.stream_id, ex.code, ex.message)
          end

          Log.debug { "Validated headers: #{validated_headers.inspect}" }
          stream.receive_headers(validated_headers, frame.flags.end_stream?)

          # Record headers received for rapid reset protection
          @rapid_reset_protection.record_headers_received(frame.stream_id)

          if callback = @on_headers
            callback.call(stream, validated_headers, frame.flags.end_stream?)
          end
        rescue ex : HPACK::DecompressionError
          # HPACK decompression failed - connection error per RFC 7540
          Log.error { "HPACK decompression error: #{ex.message}" }
          Log.debug { "Failed header block hex: #{frame.header_block.hexstring}" }
          if ex.message.try(&.includes?("Headers size exceeds maximum"))
            @performance_metrics.security_events.record_header_size_violation
          end
          raise ConnectionError.new(ErrorCode::COMPRESSION_ERROR, ex.message)
        end
      else
        # Expecting CONTINUATION frames
        Log.debug { "HEADERS without END_HEADERS received, expecting CONTINUATION frames for stream #{frame.stream_id}" }
        @continuation_stream_id = frame.stream_id
        @continuation_headers.clear # Clear any previous data
        @continuation_headers.write(frame.header_block)
        @continuation_end_stream = frame.flags.end_stream?
        @continuation_frame_count = 0_u32
        @continuation_started_at = Time.utc
        Log.debug { "Saved #{frame.header_block.size} bytes, end_stream=#{@continuation_end_stream}" }
      end
    end

    private def handle_continuation_frame(frame : ContinuationFrame)
      Log.debug { "CONTINUATION frame received: stream_id=#{frame.stream_id}, end_headers=#{frame.flags.end_headers?}, header_block_size=#{frame.header_block.size}" }

      if @continuation_stream_id.nil?
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "CONTINUATION without HEADERS")
      end

      if @continuation_stream_id != frame.stream_id
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "CONTINUATION stream mismatch")
      end

      # Check for timeout (5 seconds for CONTINUATION sequence)
      if started_at = @continuation_started_at
        if Time.utc - started_at > 5.seconds
          # Reset continuation state
          @continuation_stream_id = nil
          @continuation_headers.clear
          @continuation_frame_count = 0_u32
          @continuation_started_at = nil
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "CONTINUATION sequence timeout")
        end
      end

      # Check if this is a closed stream
      if is_stream_closed?(frame.stream_id)
        raise StreamError.new(frame.stream_id, ErrorCode::STREAM_CLOSED, "CONTINUATION on closed stream")
      end

      # Check continuation frame count limit
      @continuation_frame_count += 1
      Log.debug { "CONTINUATION frame count: #{@continuation_frame_count}" }

      if @continuation_frame_count > Security::MAX_CONTINUATION_FRAMES
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR,
          "CONTINUATION frame count exceeds limit: #{@continuation_frame_count}")
      end

      # Check continuation size limit
      if @continuation_headers.size + frame.header_block.size > Security::MAX_CONTINUATION_SIZE
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "CONTINUATION frames exceed size limit")
      end

      @continuation_headers.write(frame.header_block)
      Log.debug { "CONTINUATION headers buffer size: #{@continuation_headers.size}" }
      Log.debug { "CONTINUATION: Added #{frame.header_block.size} bytes, total frames: #{@continuation_frame_count}" }

      if frame.flags.end_headers?
        Log.debug { "CONTINUATION: END_HEADERS received, processing complete header block" }
        stream = get_stream(frame.stream_id)
        begin
          headers = @hpack_decoder.decode(@continuation_headers.to_slice)
          Log.debug { "CONTINUATION: Decoded #{headers.size} headers" }

          # Check if this is trailers
          is_trailers = !!(stream.request_headers && stream.data.size > 0)

          # Validate headers according to HTTP/2 spec
          validator = HeaderValidator.new(is_request: true, is_trailers: is_trailers)
          begin
            validated_headers = validator.validate(headers)
          rescue ex : StreamError
            # Re-raise with correct stream ID
            raise StreamError.new(frame.stream_id, ex.code, ex.message)
          end

          # Use tracked END_STREAM flag from original HEADERS frame
          end_stream = @continuation_end_stream

          stream.receive_headers(validated_headers, end_stream)

          if callback = @on_headers
            Log.debug { "CONTINUATION: Invoking on_headers callback with #{validated_headers.size} headers, end_stream=#{end_stream}" }
            callback.call(stream, validated_headers, end_stream)
          else
            Log.debug { "CONTINUATION: No on_headers callback set!" }
          end
        rescue ex : HPACK::DecompressionError
          # HPACK decompression failed - connection error per RFC 7540
          if ex.message.try(&.includes?("Headers size exceeds maximum"))
            @performance_metrics.security_events.record_header_size_violation
          end
          raise ConnectionError.new(ErrorCode::COMPRESSION_ERROR, ex.message)
        end

        @continuation_stream_id = nil
        @continuation_headers.clear
        @continuation_frame_count = 0_u32
        @continuation_started_at = nil
        Log.debug { "CONTINUATION: Processing complete, state cleared" }
      else
        Log.debug { "CONTINUATION: Waiting for more frames (no END_HEADERS yet)" }
      end

      Log.debug { "CONTINUATION handler completed for stream #{frame.stream_id}" }
    end

    private def handle_priority_frame(frame : PriorityFrame)
      unless @priority_rate_limiter.check
        @performance_metrics.security_events.record_priority_flood_attempt
        raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "PRIORITY flood detected")
      end

      # Check if stream already exists
      if stream = @streams[frame.stream_id]?
        # Existing stream - just update priority
        stream.receive_priority(frame.priority)
      else
        # Stream doesn't exist - could be an idle stream
        # For idle streams, we create a priority-only placeholder without updating last_stream_id
        # per RFC 7540 Section 5.3.2: PRIORITY can be sent for streams in any state

        # Still need to validate stream ID format
        if frame.stream_id.even?
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Client must use odd-numbered stream IDs")
        end

        # Create stream without updating last_stream_id for idle streams
        stream = Stream.new(self, frame.stream_id, StreamState::IDLE)
        stream.receive_priority(frame.priority)
        @streams[frame.stream_id] = stream

        # Don't update last_stream_id for priority-only streams
        # This allows lower stream IDs to be created later
      end
    end

    private def handle_rst_stream_frame(frame : RstStreamFrame)
      unless @rst_rate_limiter.check
        @performance_metrics.security_events.record_window_update_flood_attempt
        raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "RST_STREAM flood detected")
      end

      stream = @streams[frame.stream_id]?

      # RST_STREAM on idle stream is a protocol error
      if stream.nil? && frame.stream_id > @last_stream_id
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "RST_STREAM on idle stream")
      end

      return unless stream

      # Record cancellation for rapid reset detection
      unless @rapid_reset_protection.record_stream_cancelled(frame.stream_id, @connection_id)
        @performance_metrics.security_events.record_rapid_reset_attempt
        raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "Rapid reset attack detected")
      end

      stream.receive_rst_stream(frame.error_code)
      mark_stream_closed(frame.stream_id)
      @rapid_reset_protection.record_stream_closed(frame.stream_id)

      # Track metrics
      @metrics.record_stream_closed(frame.stream_id)
      @performance_metrics.record_stream_completed(frame.stream_id)
    end

    private def handle_settings_frame(frame : SettingsFrame)
      if frame.flags.ack?
        # Settings acknowledged - notify the oldest pending settings
        # Use non-blocking send to avoid deadlock when no fiber is waiting
        select
        when @settings_ack_channel.send(nil)
          # Successfully notified
        else
          # No fiber waiting, which is fine
        end

        # Also notify any pending update_settings calls
        if channel = @pending_settings.shift?
          channel.send(nil)
        end
      else
        # Rate limit SETTINGS frames
        unless @settings_rate_limiter.check
          @performance_metrics.security_events.record_settings_flood_attempt
          raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "SETTINGS flood detected")
        end

        # Validate and apply remote settings
        begin
          apply_remote_settings(frame.settings)
          # Send ACK only if all settings were successfully applied
          Log.debug { "Sending SETTINGS ACK" }
          send_frame(SettingsFrame.new(FrameFlags::ACK))
          Log.debug { "SETTINGS ACK sent" }
        rescue ex : ConnectionError
          # Settings validation failed - send GOAWAY
          send_goaway(ex.code, ex.message || "")
          raise ex
        end
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
          @performance_metrics.security_events.record_ping_flood_attempt
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
          @metrics.record_stream_closed(id)
          @performance_metrics.record_stream_completed(id)
        end
      end
    end

    private def handle_window_update_frame(frame : WindowUpdateFrame)
      Log.debug { "Received WINDOW_UPDATE: stream_id=#{frame.stream_id}, increment=#{frame.window_size_increment}" }

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
        Log.debug { "Connection window updated to #{@window_size}" }
      else
        # Stream window update
        stream = get_stream(frame.stream_id)
        stream.update_send_window(frame.window_size_increment.to_i32)
      end
    end

    private def get_stream(stream_id : UInt32) : Stream
      @streams[stream_id] || raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Unknown stream #{stream_id}")
    end

    def mark_stream_closed(stream_id : UInt32) : Nil
      @streams.delete(stream_id)
      @closed_streams << stream_id

      # Limit the size of closed streams set
      if @closed_streams.size > @closed_stream_limit
        # Remove oldest closed streams (lower IDs)
        oldest_ids = @closed_streams.to_a.sort.first(@closed_streams.size - @closed_stream_limit)
        oldest_ids.each { |id| @closed_streams.delete(id) }
      end
    end

    # Check if a stream is closed (public for testing)
    def is_stream_closed?(stream_id : UInt32) : Bool
      @closed_streams.includes?(stream_id)
    end

    def apply_remote_settings(settings : SettingsFrame::Settings) : Nil
      settings.each do |param, value|
        validate_setting(param, value)
        apply_single_setting(param, value)
        @remote_settings[param] = value
        @applied_settings[param] = value
      end
    end

    private def apply_single_setting(param : SettingsParameter, value : UInt32) : Nil
      case param
      when SettingsParameter::HEADER_TABLE_SIZE
        @hpack_encoder.update_dynamic_table_size(value)
      when SettingsParameter::INITIAL_WINDOW_SIZE
        update_stream_windows(value)
      when SettingsParameter::MAX_HEADER_LIST_SIZE
        @hpack_decoder.max_headers_size = value
      when SettingsParameter::MAX_FRAME_SIZE
        # Will be used for future frame writes
      when SettingsParameter::MAX_CONCURRENT_STREAMS
        # Just prevent new streams from being created
      when SettingsParameter::ENABLE_PUSH
        # No immediate action needed
      end
    end

    private def update_stream_windows(new_initial_window : UInt32) : Nil
      old_value = @remote_settings[SettingsParameter::INITIAL_WINDOW_SIZE]? || DEFAULT_INITIAL_WINDOW_SIZE
      diff = new_initial_window.to_i64 - old_value.to_i64

      @streams.each_value do |stream|
        new_window = stream.send_window_size.to_i64 + diff
        if new_window > Security::MAX_WINDOW_SIZE
          raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "Window size overflow on stream #{stream.id}")
        end
        # Allow negative windows - RFC 7540 Section 6.9.2
        # "A sender MUST track the negative flow-control window"
        stream.send_window_size = new_window.to_i32
      end
    end

    private def validate_setting(param : SettingsParameter, value : UInt32) : Nil
      case param
      when SettingsParameter::ENABLE_PUSH
        if value > 1
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "ENABLE_PUSH must be 0 or 1")
        end
      when SettingsParameter::INITIAL_WINDOW_SIZE
        # Window size is UInt32 but needs to be treated as Int32 for flow control
        if value > 0x7FFFFFFF
          raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "INITIAL_WINDOW_SIZE too large: #{value}")
        end
      when SettingsParameter::MAX_FRAME_SIZE
        if value < 16_384 || value > 16_777_215
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "MAX_FRAME_SIZE out of range")
        end
      when SettingsParameter::MAX_CONCURRENT_STREAMS
        # No specific validation, 0 means unlimited
      when SettingsParameter::HEADER_TABLE_SIZE
        # No specific max defined in RFC
      when SettingsParameter::MAX_HEADER_LIST_SIZE
        # No specific validation, implementation defined
      end
    end

    private def get_or_create_stream(stream_id : UInt32) : Stream
      # Check if stream already exists (possibly from PRIORITY frame)
      if existing_stream = @streams[stream_id]?
        return existing_stream
      end

      # Create new stream
      # Client-initiated streams must use odd-numbered stream IDs
      # Server-initiated streams use even-numbered IDs (but we're a server, so we expect odd from clients)
      if stream_id.even?
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Client must use odd-numbered stream IDs")
      end

      if stream_id <= @last_stream_id
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Stream ID not increasing")
      end

      # Check rapid reset protection
      if @rapid_reset_protection.banned?(@connection_id)
        @performance_metrics.security_events.record_connection_rejected
        raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "Connection banned due to rapid reset attack")
      end

      unless @rapid_reset_protection.record_stream_created(stream_id, @connection_id)
        @performance_metrics.security_events.record_connection_rate_limited
        raise ConnectionError.new(ErrorCode::ENHANCE_YOUR_CALM, "Stream creation rate limit exceeded")
      end

      # Check concurrent stream limit
      active_streams = @streams.count { |_, stream| !stream.closed? }
      max_streams = @local_settings[SettingsParameter::MAX_CONCURRENT_STREAMS]

      if active_streams >= max_streams
        @performance_metrics.security_events.record_stream_limit_violation
        raise ConnectionError.new(ErrorCode::REFUSED_STREAM, "Maximum concurrent streams (#{max_streams}) reached")
      end

      # Check total stream limit
      if @total_streams_count >= Security::MAX_TOTAL_STREAMS
        raise ConnectionError.new(ErrorCode::REFUSED_STREAM, "Total stream limit reached")
      end

      @last_stream_id = stream_id
      @total_streams_count += 1

      # Track metrics
      @metrics.record_stream_created(stream_id)
      @performance_metrics.record_stream_created(stream_id)
      @stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::CREATED,
        stream_id,
        "Stream created by server"
      )

      # Create new stream
      stream = Stream.new(self, stream_id, StreamState::IDLE)
      @streams[stream_id] = stream
      stream
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

    # Dump comprehensive connection state for debugging
    def dump_state : String
      String.build do |str|
        metrics = @metrics.snapshot
        str << "=== HTTP/2 Connection State Dump ===\n"
        str << "Connection ID: #{@connection_id}\n"
        str << "Type: #{@is_server ? "Server" : "Client"}\n"
        str << "Created: #{metrics[:started_at]}\n"
        str << "Uptime: #{metrics[:uptime_seconds].round(2)}s\n"
        str << "Idle: #{metrics[:idle_seconds].round(2)}s\n"
        str << "Status: #{connection_status}\n"
        str << "\n"

        str << "=== Connection State ===\n"
        str << "Closed: #{@closed}\n"
        str << "GOAWAY Sent: #{@goaway_sent}\n"
        str << "GOAWAY Received: #{@goaway_received}\n"
        str << "Window Size: #{@window_size}\n"
        str << "Last Stream ID: #{@last_stream_id}\n"
        str << "\n"

        str << "=== Settings ===\n"
        str << "Local Settings:\n"
        dump_settings(str, @local_settings, "  ")
        str << "Remote Settings:\n"
        dump_settings(str, @remote_settings, "  ")
        str << "Applied Settings:\n"
        dump_settings(str, @applied_settings, "  ")
        str << "\n"

        str << "=== Streams (#{@streams.size} active) ===\n"
        @streams.each do |id, stream|
          dump_stream_state(str, id, stream)
        end
        str << "\n"

        str << "=== Flow Control ===\n"
        str << "Strategy: #{@flow_controller.strategy}\n"
        str << "Initial Window: #{@flow_controller.initial_window_size}\n"
        str << "Min Threshold: #{@flow_controller.min_update_threshold}\n"
        str << "Max Threshold: #{@flow_controller.max_update_threshold}\n"
        str << "Current Threshold: #{@flow_controller.current_threshold}\n"
        str << "\n"

        str << "=== Backpressure ===\n"
        bp_metrics = @backpressure_manager.connection_metrics
        str << "Connection Pressure: #{(bp_metrics[:pressure] * 100).round(1)}%\n"
        str << "Pending Bytes: #{bp_metrics[:pending_bytes]}\n"
        str << "Pending Frames: #{bp_metrics[:pending_frames]}\n"
        str << "Paused: #{@backpressure_manager.paused?}\n"
        str << "Stream Pressures:\n"
        @streams.each do |stream_id, stream|
          stream_pressure = @backpressure_manager.stream_pressure(stream_id)
          str << "  Stream #{stream_id}: #{(stream_pressure * 100).round(1)}%\n"
        end
        str << "\n"

        str << "=== Buffer Management ===\n"
        str << "Read Buffer Size: #{@read_buffer.size}\n"
        str << "Buffer Pool Stats:\n"
        pool_stats = @buffer_pool.stats
        str << "  Max Pool Size: #{pool_stats[:max_size]}\n"
        str << "  Available: #{pool_stats[:available]}\n"
        str << "  In Use: #{pool_stats[:max_size] - pool_stats[:available]}\n"
        str << "\n"

        str << "=== HPACK State ===\n"
        str << "Encoder Table Size: #{@hpack_encoder.dynamic_table_size}/#{@hpack_encoder.max_dynamic_table_size}\n"
        str << "Decoder Table Size: #{@hpack_decoder.dynamic_table_size}/#{@hpack_decoder.max_dynamic_table_size}\n"
        str << "\n"

        str << "=== Metrics Summary ===\n"
        str << "Streams: #{metrics[:streams][:current]} active, "
        str << "#{metrics[:streams][:created]} created, "
        str << "#{metrics[:streams][:closed]} closed\n"
        str << "Bytes: #{metrics[:bytes][:sent]} sent, #{metrics[:bytes][:received]} received\n"
        str << "Frames Sent: #{metrics[:frames][:sent][:total]}\n"
        str << "Frames Received: #{metrics[:frames][:received][:total]}\n"
        str << "Flow Control Stalls: #{metrics[:flow_control][:stalls]}\n"
        str << "\n"

        str << "=== Security Status ===\n"
        reset_metrics = @rapid_reset_protection.metrics
        str << "Rapid Reset Metrics:\n"
        str << "  Active Streams: #{reset_metrics[:active_streams]}\n"
        str << "  Pending Streams: #{reset_metrics[:pending_streams]}\n"
        str << "  Banned Connections: #{reset_metrics[:banned_connections]}\n"
        str << "  Rapid Reset Counts: #{reset_metrics[:rapid_reset_counts]}\n"
      end
    end

    private def connection_status : String
      if @closed
        "Closed"
      elsif @goaway_sent || @goaway_received
        parts = [] of String
        parts << "sent" if @goaway_sent
        parts << "received" if @goaway_received
        "Closing (GOAWAY #{parts.join("/")})"
      else
        "Active"
      end
    end

    private def dump_settings(str : String::Builder, settings : SettingsFrame::Settings, indent : String) : Nil
      settings.each do |param, value|
        str << indent << "#{param}: #{value}\n"
      end
    end

    private def dump_stream_state(str : String::Builder, id : UInt32, stream : Stream) : Nil
      str << "  Stream #{id}:\n"
      str << "    State: #{stream.state}\n"
      str << "    Send Window: #{stream.send_window_size}\n"
      str << "    Recv Window: #{stream.recv_window_size}\n"
      str << "    Priority: #{stream.priority}\n"
      str << "    End Stream Sent: #{stream.end_stream_sent?}\n"
      str << "    End Stream Received: #{stream.end_stream_received?}\n"
    end

    # Enable or disable stream lifecycle tracing
    def enable_stream_tracing(enabled : Bool) : Nil
      @stream_lifecycle_tracer.enabled = enabled
    end

    # Check if stream lifecycle tracing is enabled
    def stream_tracing_enabled? : Bool
      @stream_lifecycle_tracer.enabled?
    end

    # Get stream lifecycle report
    def stream_lifecycle_report : String
      @stream_lifecycle_tracer.generate_report
    end

    # Get detailed trace for a specific stream
    def stream_trace(stream_id : UInt32) : String
      @stream_lifecycle_tracer.get_stream_trace(stream_id)
    end

    # Clear all stream lifecycle traces
    def clear_stream_traces : Nil
      @stream_lifecycle_tracer.clear
    end
  end
end
