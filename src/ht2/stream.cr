require "./adaptive_flow_control"
require "./content_length_validator"
require "./security"
require "./stream_state_machine"
require "log"

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
    getter state_machine : StreamStateMachine
    getter connection : Connection
    property send_window_size : Int64
    property recv_window_size : Int64
    getter priority : PriorityData?
    property closed_at : Time?

    property request_headers : Array(Tuple(String, String))?
    property response_headers : Array(Tuple(String, String))?
    property request_trailers : Array(Tuple(String, String))?
    property response_trailers : Array(Tuple(String, String))?
    property data : IO::Memory
    property? end_stream_sent : Bool
    property? end_stream_received : Bool

    def received_data : Bytes
      @data.to_slice
    end

    def initialize(@connection : Connection, @id : UInt32, initial_state : StreamState = StreamState::IDLE)
      @state_machine = StreamStateMachine.new(@id, initial_state)
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
      @content_length_validator = ContentLengthValidator.new
      @window_update_channel = Channel(Nil).new(1)
    end

    def send_headers(headers : Array(Tuple(String, String)), end_stream : Bool = false) : Nil
      Log.debug { "Stream #{@id}: send_headers called with #{headers.size} headers, end_stream=#{end_stream}" }
      @state_machine.validate_send_headers

      @response_headers = headers
      header_block = @connection.hpack_encoder.encode(headers)

      # max_frame_size = @connection.remote_settings[SettingsParameter::MAX_FRAME_SIZE]

      # Always use single HEADERS frame for now
      # The connection layer will handle splitting if needed
      flags = FrameFlags::END_HEADERS
      flags = flags | FrameFlags::END_STREAM if end_stream

      frame = HeadersFrame.new(@id, header_block, flags)
      Log.debug { "Stream #{@id}: Sending HEADERS frame with flags=#{flags}, header_block_size=#{header_block.size}" }
      @connection.send_frame(frame)

      @end_stream_sent = true if end_stream
      update_state_after_headers_sent(end_stream)
      Log.debug { "Stream #{@id}: send_headers completed, new state=#{state}" }
    end

    def send_data(data : Bytes, end_stream : Bool = false) : Nil
      @state_machine.validate_send_data

      Log.debug do
        "Stream.send_data: size=#{data.size}, send_window=#{@send_window_size}, " \
        "conn_window=#{@connection.window_size}"
      end

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

      # Record flow control stall if window is exhausted
      if @send_window_size <= 0
        @connection.stream_lifecycle_tracer.record_event(
          StreamLifecycleTracer::EventType::FLOW_CONTROL_STALL,
          @id,
          "Send window exhausted"
        )
      end

      @end_stream_sent = true if end_stream
      update_state_after_data_sent(end_stream)
    end

    def send_data_chunked(data : Bytes, chunk_size : Int32 = 16_384, end_stream : Bool = false) : Nil
      @state_machine.validate_send_data
      adaptive_chunk_size = get_adaptive_chunk_size(chunk_size)
      send_chunks(adaptive_chunk_size, data, end_stream)
    end

    private def get_adaptive_chunk_size(default_size : Int32) : Int32
      if buffer_mgr = @connection.adaptive_buffer_manager
        # Safely handle window sizes, converting to Int32 range
        # Don't clamp to 0 - we need actual values for proper calculations
        send_window = if @send_window_size > Int32::MAX
                        Int32::MAX
                      elsif @send_window_size < Int32::MIN
                        Int32::MIN
                      else
                        @send_window_size.to_i32
                      end
        
        conn_window = if @connection.window_size > Int32::MAX
                        Int32::MAX
                      elsif @connection.window_size < Int32::MIN
                        Int32::MIN
                      else
                        @connection.window_size.to_i32
                      end
        
        available_window = Math.min(send_window, conn_window)
        # Only clamp to 0 for the buffer manager
        buffer_mgr.recommended_chunk_size(Math.max(0, available_window))
      else
        default_size
      end
    end

    private def send_chunks(chunk_size : Int32, data : Bytes, end_stream : Bool) : Nil
      offset = 0
      Log.debug { "Stream.send_chunks: Starting to send #{data.size} bytes in chunks of #{chunk_size}" }

      while offset < data.size
        available = calculate_available_size(chunk_size)

        if available <= 0
          Log.debug { "Stream.send_chunks: No window available, waiting..." }
          wait_for_window
          next
        end

        offset = send_chunk(available, data, end_stream, offset)
      end

      Log.debug { "Stream.send_chunks: Finished sending all chunks" }
    end

    private def calculate_available_size(chunk_size : Int32) : Int32
      # Don't clamp to 0 - we need to track negative windows per RFC 7540
      send_window = @send_window_size
      # Connection window is Int64, need to handle overflow carefully
      conn_window = if @connection.window_size > Int32::MAX
                      Int32::MAX
                    elsif @connection.window_size < Int32::MIN
                      Int32::MIN
                    else
                      @connection.window_size.to_i32
                    end

      Math.min(
        Math.min(chunk_size, send_window),
        conn_window
      ).to_i32
    end

    private def wait_for_window : Nil
      # Use channel-based waiting with timeout
      timeout_channel = Channel(Nil).new

      spawn do
        sleep 5.seconds
        select
        when timeout_channel.send(nil)
          # Timeout occurred
        else
          # Already resolved
        end
      end

      loop do
        select
        when @window_update_channel.receive
          # Window updated, check if we can proceed
          if calculate_available_size(1) > 0
            Log.debug { "Stream #{@id}: Window available after update, proceeding" }
            return
          else
            Log.debug { "Stream #{@id}: Window still not available after update, continuing to wait" }
            # Continue waiting for more updates
          end
        when timeout_channel.receive
          Log.warn { "Stream #{@id}: Timed out waiting for window update" }
          raise StreamError.new(@id, ErrorCode::FLOW_CONTROL_ERROR,
            "Timed out waiting for flow control window")
        end
      end
    end

    private def wait_for_window_polling : Nil
      # Fallback polling method
      wait_time = 1.millisecond
      max_wait = 100.milliseconds
      total_waited = 0.milliseconds
      max_total_wait = 1.second

      while total_waited < max_total_wait
        Fiber.yield
        sleep wait_time

        if calculate_available_size(1) > 0
          return
        end

        total_waited += wait_time
        wait_time = Math.min(wait_time * 2, max_wait)
      end

      raise StreamError.new(@id, ErrorCode::FLOW_CONTROL_ERROR,
        "Timed out waiting for flow control window")
    end

    private def send_chunk(available : Int32, data : Bytes, end_stream : Bool, offset : Int32) : Int32
      chunk_end = Math.min(offset + available, data.size)
      chunk = data[offset...chunk_end]
      is_last_chunk = chunk_end >= data.size

      Log.debug do
        "Stream.send_chunk: Sending chunk from #{offset} to #{chunk_end} " \
        "(#{chunk.size} bytes), last_chunk=#{is_last_chunk}"
      end
      send_data(chunk, end_stream && is_last_chunk)
      chunk_end
    end

    # Send data using multiple frames efficiently
    def send_data_multi(chunks : Array(Bytes), end_stream : Bool = false) : Nil
      @state_machine.validate_send_data

      # Use connection's multi-frame method for efficiency
      @connection.send_data_frames(@id, chunks, end_stream)

      @end_stream_sent = true if end_stream
      update_state_after_data_sent(end_stream)
    end

    def send_rst_stream(error_code : ErrorCode) : Nil
      if state == StreamState::CLOSED
        return
      end

      previous_state = state

      frame = RstStreamFrame.new(@id, error_code)
      @connection.send_frame(frame)

      # Transition state machine
      event = StreamStateMachine.rst_stream_event(true)
      new_state, _ = @state_machine.transition(event)

      @closed_at = Time.utc
      @connection.metrics.record_stream_closed

      # Record RST_STREAM sent event
      @connection.stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::RST_SENT,
        @id,
        "RST_STREAM sent with #{error_code}"
      )

      # Record state change to CLOSED
      @connection.stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::STATE_CHANGE,
        @id,
        "Stream reset with #{error_code}",
        previous_state,
        new_state
      )

      # Record stream closed
      @connection.stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::CLOSED,
        @id,
        "Stream closed by RST_STREAM"
      )
    end

    def receive_headers(headers : Array(Tuple(String, String)), end_stream : Bool, priority : Bool = false) : Nil
      @state_machine.validate_receive_headers

      # Check if we already received headers
      if @request_headers
        # Second HEADERS frame - could be trailers or a protocol error
        # Trailers are only allowed if:
        # 1. The stream is in a state that allows receiving data/trailers (OPEN, HALF_CLOSED_LOCAL)
        # 2. We haven't received END_STREAM yet (trailers must have END_STREAM set)
        # 3. The current HEADERS frame has END_STREAM set
        if (state == StreamState::OPEN || state == StreamState::HALF_CLOSED_LOCAL) && !@end_stream_received && end_stream
          # This is trailers
          @request_trailers = headers
          @end_stream_received = true
          update_state_after_trailers_received
          return
        else
          # Second HEADERS frame without END_STREAM or in wrong state is a protocol error
          raise StreamError.new(@id, ErrorCode::PROTOCOL_ERROR, "Already received headers for this stream")
        end
      end

      @request_headers = headers

      # Set up content-length validation
      begin
        @content_length_validator.set_expected_length(headers)
      rescue ex : StreamError
        # Re-raise with correct stream ID
        raise StreamError.new(@id, ex.code, ex.message)
      end

      # If end_stream is set with content-length, validate it's 0
      if end_stream && @content_length_validator.has_content_length?
        if @content_length_validator.expected_length != 0
          raise StreamError.new(@id, ErrorCode::PROTOCOL_ERROR,
            "END_STREAM set but content-length is #{@content_length_validator.expected_length}")
        end
      end

      @end_stream_received = true if end_stream
      update_state_after_headers_received(end_stream)
    end

    def receive_data(data : Bytes, end_stream : Bool) : Nil
      @state_machine.validate_receive_data

      # Validate content-length
      begin
        @content_length_validator.add_data(data)
      rescue ex : StreamError
        # Re-raise with correct stream ID
        raise StreamError.new(@id, ex.code, ex.message)
      end

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

            # Record window update sent event
            @connection.stream_lifecycle_tracer.record_event(
              StreamLifecycleTracer::EventType::WINDOW_UPDATE_SENT,
              @id,
              "Window update sent: increment=#{increment}, new_window=#{@recv_window_size}"
            )
          end
        end

        # Record stall if window is exhausted
        if @recv_window_size <= 0
          @flow_controller.record_stall

          # Record flow control stall event
          @connection.stream_lifecycle_tracer.record_event(
            StreamLifecycleTracer::EventType::FLOW_CONTROL_STALL,
            @id,
            "Receive window exhausted"
          )
        end
      end

      if end_stream
        # Validate content-length on stream end
        begin
          @content_length_validator.validate_end_of_stream
        rescue ex : StreamError
          # Re-raise with correct stream ID
          raise StreamError.new(@id, ex.code, ex.message)
        end
        @end_stream_received = true
      end

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

      # Record window update received event
      @connection.stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::WINDOW_UPDATE_RECEIVED,
        @id,
        "Send window updated by #{increment} to #{new_window}"
      )

      # Notify any waiting fibers
      notify_window_update
    end

    def update_recv_window(increment : Int32) : Nil
      # In CLOSED state, ignore window updates
      return if state == StreamState::CLOSED

      # In IDLE state, window updates are not allowed
      if state == StreamState::IDLE
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
      # RST_STREAM is allowed in CLOSED state - just ignore it
      if state == StreamState::CLOSED
        return
      end

      previous_state = state

      # Transition state machine
      event = StreamStateMachine.rst_stream_event(false)
      new_state, _ = @state_machine.transition(event)

      @closed_at = Time.utc
      @connection.metrics.record_stream_closed

      # Record RST_STREAM received event
      @connection.stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::RST_RECEIVED,
        @id,
        "RST_STREAM received with #{error_code}"
      )

      # Record state change to CLOSED
      if previous_state != new_state
        @connection.stream_lifecycle_tracer.record_event(
          StreamLifecycleTracer::EventType::STATE_CHANGE,
          @id,
          "Stream reset by peer with #{error_code}",
          previous_state,
          new_state
        )
      end

      # Record stream closed
      @connection.stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::CLOSED,
        @id,
        "Stream closed by RST_STREAM from peer"
      )
    end

    def receive_priority(priority : PriorityData) : Nil
      # Check for self-dependency
      if priority.stream_dependency == @id
        raise StreamError.new(@id, ErrorCode::PROTOCOL_ERROR, "Stream cannot depend on itself")
      end

      # PRIORITY frames are allowed in any state, including CLOSED
      # for a short period after stream closure
      if state == StreamState::CLOSED && @closed_at
        # Allow PRIORITY frames for 2 seconds after closure
        closed_at = @closed_at
        return unless closed_at
        elapsed = Time.utc - closed_at
        return if elapsed > 2.seconds
      end
      @priority = priority

      # Record priority update event
      @connection.stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::PRIORITY_UPDATED,
        @id,
        String.build do |str|
          str << "Priority updated: weight=#{priority.weight}"
          str << ", exclusive=#{priority.exclusive?}"
          str << ", dependency=#{priority.stream_dependency}"
        end
      )
    end

    private def update_state_after_headers_sent(end_stream : Bool)
      previous_state = state

      # Transition state machine
      event = StreamStateMachine.headers_event(end_stream, true)
      new_state, _ = @state_machine.transition(event)

      # Update closed timestamp if needed
      if new_state == StreamState::CLOSED
        @closed_at = Time.utc
        @connection.mark_stream_closed(@id)
      end

      # Record state change if occurred
      if previous_state != new_state
        @connection.stream_lifecycle_tracer.record_event(
          StreamLifecycleTracer::EventType::STATE_CHANGE,
          @id,
          "Headers sent#{end_stream ? " with END_STREAM" : ""}",
          previous_state,
          new_state
        )
      end

      # Record headers sent event
      @connection.stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::HEADERS_SENT,
        @id,
        "Headers sent#{end_stream ? " with END_STREAM" : ""}"
      )
    end

    private def update_state_after_data_sent(end_stream : Bool)
      # Record data sent event
      @connection.stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::DATA_SENT,
        @id,
        "Data sent#{end_stream ? " with END_STREAM" : ""}"
      )

      return unless end_stream

      previous_state = state

      # Transition state machine
      event = StreamStateMachine.data_event(end_stream, true)
      new_state, _ = @state_machine.transition(event)

      # Update closed timestamp if needed
      if new_state == StreamState::CLOSED
        @closed_at = Time.utc
        @connection.mark_stream_closed(@id)
      end

      # Record state change if occurred
      if previous_state != new_state
        @connection.stream_lifecycle_tracer.record_event(
          StreamLifecycleTracer::EventType::STATE_CHANGE,
          @id,
          "Data sent with END_STREAM",
          previous_state,
          new_state
        )
      end

      # Record stream closed if applicable
      if new_state == StreamState::CLOSED
        @connection.stream_lifecycle_tracer.record_event(
          StreamLifecycleTracer::EventType::CLOSED,
          @id,
          "Stream closed after sending data"
        )
      end
    end

    private def update_state_after_headers_received(end_stream : Bool)
      previous_state = state

      # Transition state machine
      event = StreamStateMachine.headers_event(end_stream, false)
      new_state, _ = @state_machine.transition(event)

      # Update closed timestamp if needed
      if new_state == StreamState::CLOSED
        @closed_at = Time.utc
        @connection.mark_stream_closed(@id)
      end

      # Record state change if occurred
      if previous_state != new_state
        @connection.stream_lifecycle_tracer.record_event(
          StreamLifecycleTracer::EventType::STATE_CHANGE,
          @id,
          "Headers received#{end_stream ? " with END_STREAM" : ""}",
          previous_state,
          new_state
        )
      end

      # Record headers received event
      @connection.stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::HEADERS_RECEIVED,
        @id,
        "Headers received#{end_stream ? " with END_STREAM" : ""}"
      )

      # Record stream closed if applicable
      if new_state == StreamState::CLOSED
        @connection.stream_lifecycle_tracer.record_event(
          StreamLifecycleTracer::EventType::CLOSED,
          @id,
          "Stream closed after receiving headers"
        )
      end
    end

    private def update_state_after_data_received(end_stream : Bool)
      # Record data received event
      @connection.stream_lifecycle_tracer.record_event(
        StreamLifecycleTracer::EventType::DATA_RECEIVED,
        @id,
        "Data received#{end_stream ? " with END_STREAM" : ""}"
      )

      return unless end_stream

      previous_state = state

      # Transition state machine
      event = StreamStateMachine.data_event(end_stream, false)
      new_state, _ = @state_machine.transition(event)

      # Update closed timestamp if needed
      if new_state == StreamState::CLOSED
        @closed_at = Time.utc
        @connection.mark_stream_closed(@id)
      end

      # Record state change if occurred
      if previous_state != new_state
        @connection.stream_lifecycle_tracer.record_event(
          StreamLifecycleTracer::EventType::STATE_CHANGE,
          @id,
          "Data received with END_STREAM",
          previous_state,
          new_state
        )
      end

      # Record stream closed if applicable
      if new_state == StreamState::CLOSED
        @connection.stream_lifecycle_tracer.record_event(
          StreamLifecycleTracer::EventType::CLOSED,
          @id,
          "Stream closed after receiving data"
        )
      end
    end

    def state : StreamState
      @state_machine.current_state
    end

    def closed? : Bool
      state == StreamState::CLOSED
    end

    private def update_state_after_trailers_received
      # Trailers are always sent with END_STREAM, so transition to closed
      previous_state = state

      # Transition state machine - trailers imply end of stream
      event = StreamStateMachine.headers_event(true, false) # end_stream = true
      new_state, _ = @state_machine.transition(event)

      # Update closed timestamp
      if new_state == StreamState::CLOSED
        @closed_at = Time.utc
        @connection.mark_stream_closed(@id)
      end

      # Record state change
      if previous_state != new_state
        @connection.stream_lifecycle_tracer.record_event(
          StreamLifecycleTracer::EventType::STATE_CHANGE,
          @id,
          "Trailers received",
          previous_state,
          new_state
        )
      end
    end

    # Notify waiting fibers that window has been updated
    def notify_window_update : Nil
      select
      when @window_update_channel.send(nil)
        # Successfully notified
      else
        # No fiber waiting, which is fine
      end
    end
  end
end
