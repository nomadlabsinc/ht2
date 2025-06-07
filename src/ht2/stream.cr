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
    property window_size : Int64
    getter priority : PriorityData?

    property request_headers : Array(Tuple(String, String))?
    property response_headers : Array(Tuple(String, String))?
    property data : IO::Memory
    property? end_stream_sent : Bool
    property? end_stream_received : Bool

    def initialize(@id : UInt32, @connection : Connection, @state : StreamState = StreamState::IDLE)
      @window_size = connection.remote_settings[SettingsParameter::INITIAL_WINDOW_SIZE].to_i64
      @priority = nil
      @data = IO::Memory.new
      @end_stream_sent = false
      @end_stream_received = false
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
      if data.size > @window_size
        raise StreamError.new(@id, ErrorCode::FLOW_CONTROL_ERROR, "Data size exceeds window")
      end

      if data.size > @connection.window_size
        raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "Data size exceeds connection window")
      end

      flags = end_stream ? FrameFlags::END_STREAM : FrameFlags::None
      frame = DataFrame.new(@id, data, flags)
      @connection.send_frame(frame)

      @window_size -= data.size
      @connection.consume_window(data.size)

      @end_stream_sent = true if end_stream
      update_state_after_data_sent(end_stream)
    end

    def send_rst_stream(error_code : ErrorCode) : Nil
      if @state == StreamState::CLOSED
        return
      end

      frame = RstStreamFrame.new(@id, error_code)
      @connection.send_frame(frame)
      @state = StreamState::CLOSED
    end

    def receive_headers(headers : Array(Tuple(String, String)), end_stream : Bool) : Nil
      validate_receive_headers

      @request_headers = headers
      @end_stream_received = true if end_stream
      update_state_after_headers_received(end_stream)
    end

    def receive_data(data : Bytes, end_stream : Bool) : Nil
      validate_receive_data

      @data.write(data)
      @end_stream_received = true if end_stream
      update_state_after_data_received(end_stream)
    end

    def receive_window_update(increment : UInt32) : Nil
      # Check for zero increment
      if increment == 0
        raise StreamError.new(@id, ErrorCode::PROTOCOL_ERROR, "Window increment cannot be zero")
      end

      # Use checked arithmetic
      new_window = Security.checked_add(@window_size, increment.to_i64)

      if new_window > Security::MAX_WINDOW_SIZE
        raise StreamError.new(@id, ErrorCode::FLOW_CONTROL_ERROR, "Window size overflow")
      end

      @window_size = new_window
    end

    def receive_rst_stream : Nil
      @state = StreamState::CLOSED
    end

    def receive_priority(priority : PriorityData) : Nil
      @priority = priority
    end

    private def validate_send_headers
      case @state
      when StreamState::IDLE, StreamState::RESERVED_LOCAL
        # OK
      when StreamState::HALF_CLOSED_REMOTE
        # OK for trailers
      else
        raise StreamError.new(@id, ErrorCode::PROTOCOL_ERROR, "Cannot send headers in state #{@state}")
      end
    end

    private def validate_send_data
      case @state
      when StreamState::OPEN, StreamState::HALF_CLOSED_REMOTE
        # OK
      else
        raise StreamError.new(@id, ErrorCode::PROTOCOL_ERROR, "Cannot send data in state #{@state}")
      end
    end

    private def validate_receive_headers
      case @state
      when StreamState::IDLE, StreamState::RESERVED_REMOTE
        # OK
      when StreamState::HALF_CLOSED_LOCAL
        # OK for trailers
      else
        raise StreamError.new(@id, ErrorCode::PROTOCOL_ERROR, "Cannot receive headers in state #{@state}")
      end
    end

    private def validate_receive_data
      case @state
      when StreamState::OPEN, StreamState::HALF_CLOSED_LOCAL
        # OK
      else
        raise StreamError.new(@id, ErrorCode::PROTOCOL_ERROR, "Cannot receive data in state #{@state}")
      end
    end

    private def update_state_after_headers_sent(end_stream : Bool)
      case @state
      when StreamState::IDLE
        @state = end_stream ? StreamState::HALF_CLOSED_LOCAL : StreamState::OPEN
      when StreamState::RESERVED_LOCAL
        @state = StreamState::HALF_CLOSED_REMOTE
      when StreamState::HALF_CLOSED_REMOTE
        @state = StreamState::CLOSED if end_stream
      end
    end

    private def update_state_after_data_sent(end_stream : Bool)
      return unless end_stream

      case @state
      when StreamState::OPEN
        @state = StreamState::HALF_CLOSED_LOCAL
      when StreamState::HALF_CLOSED_REMOTE
        @state = StreamState::CLOSED
      end
    end

    private def update_state_after_headers_received(end_stream : Bool)
      case @state
      when StreamState::IDLE
        @state = end_stream ? StreamState::HALF_CLOSED_REMOTE : StreamState::OPEN
      when StreamState::RESERVED_REMOTE
        @state = StreamState::HALF_CLOSED_LOCAL
      when StreamState::HALF_CLOSED_LOCAL
        @state = StreamState::CLOSED if end_stream
      end
    end

    private def update_state_after_data_received(end_stream : Bool)
      return unless end_stream

      case @state
      when StreamState::OPEN
        @state = StreamState::HALF_CLOSED_REMOTE
      when StreamState::HALF_CLOSED_LOCAL
        @state = StreamState::CLOSED
      end
    end

    def closed? : Bool
      @state == StreamState::CLOSED
    end
  end
end
