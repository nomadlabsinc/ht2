require "./adaptive_flow_control"
require "./security"

module HT2
  enum StreamState
    IDLE
    RESERVED_LOCAL
    RESERVED_REMOTE
    OPEN
    HALF_CLOSED_LOCAL
    HALF_CLOSED_REMOTE
    CLOSED
  end

  class Stream
    getter id : UInt32
    property state : StreamState
    getter connection : Connection
    property send_window_size : Int64
    property recv_window_size : Int64
    getter priority : PriorityData?
    property closed_at : Time?

    property request_headers : Array(Tuple(String, String))?
    property response_headers : Array(Tuple(String, String))?
    property data : IO::Memory
    property? end_stream_sent : Bool
    property? end_stream_received : Bool

    def received_data : Bytes
      @data.to_slice
    end

    def initialize(@connection : Connection, @id : UInt32, @state : StreamState = StreamState::IDLE)
      @send_window_size = connection.remote_settings[SettingsParameter::INITIAL_WINDOW_SIZE].to_i64
      @recv_window_size = connection.local_settings[SettingsParameter::INITIAL_WINDOW_SIZE].to_i64
      @priority = nil
      @data = IO::Memory.new
      @end_stream_sent = false
      @end_stream_received = false
      @closed_at = nil
      @flow_controller = AdaptiveFlowControl.new(
        @recv_window_size,
        AdaptiveFlowControl::Strategy::DYNAMIC
      )
    end

    def send_headers(headers : Array(Tuple(String, String)), end_stream : Bool = false) : Nil
      validate_send_headers

      @response_headers = headers
      header_block = @connection.hpack_encoder.encode(headers)

      flags = FrameFlags::END_HEADERS
      flags = flags | FrameFlags::END_STREAM if end_stream

      frame = HeadersFrame.new(@id, header_block, flags)
      @connection.send_frame(frame)

      @end_stream_sent = true if end_stream
      update_state_after_headers_sent(end_stream)
    end

    def send_data(data : Bytes, end_stream : Bool = false) : Nil
      validate_send_data

      # Check flow control window
      if data.size > @send_window_size
        raise StreamError.new(@id, ErrorCode::FLOW_CONTROL_ERROR, "Data size exceeds window")
      end

      if data.size > @connection.window_size
        raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "Data size exceeds connection window")
      end

      # Check backpressure before sending
      backpressure = @connection.backpressure_manager.stream_pressure(@id)
      if backpressure > 0.9
        # Wait for capacity with a reasonable timeout
        unless @connection.backpressure_manager.wait_for_capacity(500.milliseconds)
          raise StreamError.new(@id, ErrorCode::FLOW_CONTROL_ERROR, "Stream backpressure timeout")
        end
      end

      flags = end_stream ? FrameFlags::END_STREAM : FrameFlags::None
      frame = DataFrame.new(@id, data, flags)
      @connection.send_frame(frame)

      @send_window_size -= data.size
      @connection.consume_window(data.size)

      @end_stream_sent = true if end_stream
      update_state_after_data_sent(end_stream)
    end

    def send_data_chunked(data : Bytes, chunk_size : Int32 = 16_384, end_stream : Bool = false) : Nil
      validate_send_data
      send_chunks(chunk_size, data, end_stream)
    end

    private def send_chunks(chunk_size : Int32, data : Bytes, end_stream : Bool) : Nil
      offset = 0
      while offset < data.size
        available = calculate_available_size(chunk_size)

        if available <= 0
          wait_for_window
          next
        end

        offset = send_chunk(available, data, end_stream, offset)
      end
    end

    private def calculate_available_size(chunk_size : Int32) : Int32
      Math.min(
        chunk_size,
        @send_window_size.to_i32,
        @connection.window_size.to_i32
      )
    end

    private def wait_for_window : Nil
      sleep 10.milliseconds
    end

    private def send_chunk(available : Int32, data : Bytes, end_stream : Bool, offset : Int32) : Int32
      chunk_end = Math.min(offset + available, data.size)
      chunk = data[offset...chunk_end]
      is_last_chunk = chunk_end >= data.size
      send_data(chunk, end_stream && is_last_chunk)
      chunk_end
    end

    def send_rst_stream(error_code : ErrorCode) : Nil
      if @state == StreamState::CLOSED
        return
      end

      frame = RstStreamFrame.new(@id, error_code)
      @connection.send_frame(frame)
      @state = StreamState::CLOSED
      @closed_at = Time.utc
    end

    def receive_headers(headers : Array(Tuple(String, String)), end_stream : Bool, priority : Bool = false) : Nil
      validate_receive_headers

      @request_headers = headers
      @end_stream_received = true if end_stream
      update_state_after_headers_received(end_stream)
    end

    def receive_data(data : Bytes, end_stream : Bool) : Nil
      validate_receive_data

      # Update receive window
      @recv_window_size -= data.size
      @data.write(data)

      # Check if we need to send a window update
      if data.size > 0
        initial_window = @connection.local_settings[SettingsParameter::INITIAL_WINDOW_SIZE].to_i64
        consumed = initial_window - @recv_window_size

        if @flow_controller.needs_update?(initial_window, @recv_window_size)
          increment = @flow_controller.calculate_increment(@recv_window_size, consumed)

          if increment > 0
            # Send stream-level window update
            frame = WindowUpdateFrame.new(@id, increment.to_u32)
            @connection.send_frame(frame)
            @recv_window_size += increment
          end
        end

        # Record stall if window is exhausted
        if @recv_window_size <= 0
          @flow_controller.record_stall
        end
      end

      @end_stream_received = true if end_stream
      update_state_after_data_received(end_stream)
    end

    def update_send_window(increment : Int32) : Nil
      # Check for zero increment
      if increment == 0
        raise StreamError.new(@id, ErrorCode::PROTOCOL_ERROR, "Window increment cannot be zero")
      end

      # Use checked arithmetic
      new_window = Security.checked_add(@send_window_size, increment.to_i64)

      if new_window > Security::MAX_WINDOW_SIZE
        raise StreamError.new(@id, ErrorCode::FLOW_CONTROL_ERROR, "Window size overflow")
      end

      @send_window_size = new_window
    end

    def update_recv_window(increment : Int32) : Nil
      # In CLOSED state, ignore window updates
      return if @state == StreamState::CLOSED

      # In IDLE state, window updates are not allowed
      if @state == StreamState::IDLE
        raise ProtocolError.new("Cannot update window in IDLE state")
      end

      # Check for zero increment
      if increment == 0
        raise StreamError.new(@id, ErrorCode::PROTOCOL_ERROR, "Window increment cannot be zero")
      end

      # Use checked arithmetic
      new_window = Security.checked_add(@recv_window_size, increment.to_i64)

      if new_window > Security::MAX_WINDOW_SIZE
        raise StreamError.new(@id, ErrorCode::FLOW_CONTROL_ERROR, "Window size overflow")
      end

      @recv_window_size = new_window
    end

    def receive_rst_stream(error_code : ErrorCode) : Nil
      @state = StreamState::CLOSED
      @closed_at = Time.utc
    end

    def receive_priority(priority : PriorityData) : Nil
      # PRIORITY frames are allowed in any state, including CLOSED
      # for a short period after stream closure
      if @state == StreamState::CLOSED && @closed_at
        # Allow PRIORITY frames for 2 seconds after closure
        closed_at = @closed_at
        return unless closed_at
        elapsed = Time.utc - closed_at
        return if elapsed > 2.seconds
      end
      @priority = priority
    end

    private def validate_send_headers
      case @state
      when StreamState::IDLE, StreamState::RESERVED_LOCAL
        # OK
      when StreamState::OPEN, StreamState::HALF_CLOSED_REMOTE
        # OK for trailers after DATA
      when StreamState::CLOSED
        raise StreamClosedError.new(@id, "Cannot send headers on closed stream")
      else
        raise StreamError.new(@id, ErrorCode::PROTOCOL_ERROR, "Cannot send headers in state #{@state}")
      end
    end

    private def validate_send_data
      case @state
      when StreamState::OPEN, StreamState::HALF_CLOSED_REMOTE
        # OK
      when StreamState::CLOSED, StreamState::HALF_CLOSED_LOCAL
        raise StreamClosedError.new(@id, "Cannot send data on closed stream")
      else
        raise ProtocolError.new("Cannot send data in state #{@state}")
      end
    end

    private def validate_receive_headers
      case @state
      when StreamState::IDLE, StreamState::RESERVED_REMOTE
        # OK
      when StreamState::OPEN, StreamState::HALF_CLOSED_LOCAL
        # OK for trailers after DATA
      when StreamState::CLOSED
        raise StreamClosedError.new(@id, "Cannot receive headers on closed stream")
      else
        raise ProtocolError.new("Cannot receive headers in state #{@state}")
      end
    end

    private def validate_receive_data
      case @state
      when StreamState::OPEN, StreamState::HALF_CLOSED_LOCAL
        # OK
      when StreamState::CLOSED, StreamState::HALF_CLOSED_REMOTE
        raise StreamClosedError.new(@id, "Cannot receive data on closed stream")
      when StreamState::IDLE
        raise ProtocolError.new("Cannot receive data in IDLE state")
      else
        raise ProtocolError.new("Cannot receive data in state #{@state}")
      end
    end

    private def update_state_after_headers_sent(end_stream : Bool)
      case @state
      when StreamState::IDLE
        @state = end_stream ? StreamState::HALF_CLOSED_LOCAL : StreamState::OPEN
      when StreamState::RESERVED_LOCAL
        @state = StreamState::HALF_CLOSED_REMOTE
      when StreamState::OPEN
        # Sending headers with END_STREAM in OPEN state (trailers)
        if end_stream
          @state = StreamState::HALF_CLOSED_LOCAL
        end
      when StreamState::HALF_CLOSED_REMOTE
        if end_stream
          @state = StreamState::CLOSED
          @closed_at = Time.utc
        end
      end
    end

    private def update_state_after_data_sent(end_stream : Bool)
      return unless end_stream

      case @state
      when StreamState::OPEN
        @state = StreamState::HALF_CLOSED_LOCAL
      when StreamState::HALF_CLOSED_REMOTE
        @state = StreamState::CLOSED
        @closed_at = Time.utc
      end
    end

    private def update_state_after_headers_received(end_stream : Bool)
      case @state
      when StreamState::IDLE
        @state = end_stream ? StreamState::HALF_CLOSED_REMOTE : StreamState::OPEN
      when StreamState::RESERVED_REMOTE
        @state = StreamState::HALF_CLOSED_LOCAL
      when StreamState::HALF_CLOSED_LOCAL
        if end_stream
          @state = StreamState::CLOSED
          @closed_at = Time.utc
        end
      end
    end

    private def update_state_after_data_received(end_stream : Bool)
      return unless end_stream

      case @state
      when StreamState::OPEN
        @state = StreamState::HALF_CLOSED_REMOTE
      when StreamState::HALF_CLOSED_LOCAL
        @state = StreamState::CLOSED
        @closed_at = Time.utc
      end
    end

    def closed? : Bool
      @state == StreamState::CLOSED
    end
  end
end
