require "./errors"

module HT2
  class StreamStateMachine
    alias TransitionResult = Tuple(StreamState, Array(String))

    # Event types that can trigger state transitions
    enum Event
      SendHeaders
      SendHeadersEndStream
      SendData
      SendDataEndStream
      ReceiveHeaders
      ReceiveHeadersEndStream
      ReceiveData
      ReceiveDataEndStream
      SendRstStream
      ReceiveRstStream
    end

    # Define all valid state transitions
    TRANSITIONS = {
      # IDLE state transitions
      {StreamState::IDLE, Event::SendHeaders}             => StreamState::OPEN,
      {StreamState::IDLE, Event::SendHeadersEndStream}    => StreamState::HALF_CLOSED_LOCAL,
      {StreamState::IDLE, Event::ReceiveHeaders}          => StreamState::OPEN,
      {StreamState::IDLE, Event::ReceiveHeadersEndStream} => StreamState::HALF_CLOSED_REMOTE,
      {StreamState::IDLE, Event::SendRstStream}           => StreamState::CLOSED,
      {StreamState::IDLE, Event::ReceiveRstStream}        => StreamState::CLOSED,

      # RESERVED_LOCAL state transitions
      {StreamState::RESERVED_LOCAL, Event::SendHeaders}      => StreamState::HALF_CLOSED_REMOTE,
      {StreamState::RESERVED_LOCAL, Event::SendRstStream}    => StreamState::CLOSED,
      {StreamState::RESERVED_LOCAL, Event::ReceiveRstStream} => StreamState::CLOSED,

      # RESERVED_REMOTE state transitions
      {StreamState::RESERVED_REMOTE, Event::ReceiveHeaders}   => StreamState::HALF_CLOSED_LOCAL,
      {StreamState::RESERVED_REMOTE, Event::SendRstStream}    => StreamState::CLOSED,
      {StreamState::RESERVED_REMOTE, Event::ReceiveRstStream} => StreamState::CLOSED,

      # OPEN state transitions
      {StreamState::OPEN, Event::SendDataEndStream}       => StreamState::HALF_CLOSED_LOCAL,
      {StreamState::OPEN, Event::SendHeadersEndStream}    => StreamState::HALF_CLOSED_LOCAL,
      {StreamState::OPEN, Event::ReceiveDataEndStream}    => StreamState::HALF_CLOSED_REMOTE,
      {StreamState::OPEN, Event::ReceiveHeadersEndStream} => StreamState::HALF_CLOSED_REMOTE,
      {StreamState::OPEN, Event::SendRstStream}           => StreamState::CLOSED,
      {StreamState::OPEN, Event::ReceiveRstStream}        => StreamState::CLOSED,

      # HALF_CLOSED_LOCAL state transitions
      {StreamState::HALF_CLOSED_LOCAL, Event::ReceiveDataEndStream}    => StreamState::CLOSED,
      {StreamState::HALF_CLOSED_LOCAL, Event::ReceiveHeadersEndStream} => StreamState::CLOSED,
      {StreamState::HALF_CLOSED_LOCAL, Event::SendRstStream}           => StreamState::CLOSED,
      {StreamState::HALF_CLOSED_LOCAL, Event::ReceiveRstStream}        => StreamState::CLOSED,

      # HALF_CLOSED_REMOTE state transitions
      {StreamState::HALF_CLOSED_REMOTE, Event::SendDataEndStream}    => StreamState::CLOSED,
      {StreamState::HALF_CLOSED_REMOTE, Event::SendHeadersEndStream} => StreamState::CLOSED,
      {StreamState::HALF_CLOSED_REMOTE, Event::SendRstStream}        => StreamState::CLOSED,
      {StreamState::HALF_CLOSED_REMOTE, Event::ReceiveRstStream}     => StreamState::CLOSED,
    }

    # Define which events are allowed in each state (even if they don't cause transitions)
    ALLOWED_EVENTS = {
      StreamState::IDLE => [
        Event::SendHeaders, Event::SendHeadersEndStream,
        Event::ReceiveHeaders, Event::ReceiveHeadersEndStream,
        Event::SendRstStream, Event::ReceiveRstStream,
      ],
      StreamState::RESERVED_LOCAL => [
        Event::SendHeaders, Event::SendRstStream, Event::ReceiveRstStream,
      ],
      StreamState::RESERVED_REMOTE => [
        Event::ReceiveHeaders, Event::SendRstStream, Event::ReceiveRstStream,
      ],
      StreamState::OPEN => [
        Event::SendHeaders, Event::SendHeadersEndStream,
        Event::SendData, Event::SendDataEndStream,
        Event::ReceiveHeaders, Event::ReceiveHeadersEndStream,
        Event::ReceiveData, Event::ReceiveDataEndStream,
        Event::SendRstStream, Event::ReceiveRstStream,
      ],
      StreamState::HALF_CLOSED_LOCAL => [
        Event::ReceiveHeaders, Event::ReceiveHeadersEndStream,
        Event::ReceiveData, Event::ReceiveDataEndStream,
        Event::SendRstStream, Event::ReceiveRstStream,
      ],
      StreamState::HALF_CLOSED_REMOTE => [
        Event::SendHeaders, Event::SendHeadersEndStream,
        Event::SendData, Event::SendDataEndStream,
        Event::SendRstStream, Event::ReceiveRstStream,
      ],
      StreamState::CLOSED => [] of Event,
    }

    getter current_state : StreamState
    property stream_id : UInt32

    def initialize(@stream_id : UInt32, @current_state : StreamState = StreamState::IDLE)
    end

    # Attempt to transition to a new state based on an event
    def transition(event : Event) : TransitionResult
      # Check if event is allowed in current state
      allowed = ALLOWED_EVENTS[@current_state]?
      unless allowed && allowed.includes?(event)
        if @current_state == StreamState::CLOSED
          raise StreamClosedError.new(@stream_id, "Stream is closed")
        else
          raise ProtocolError.new("Event #{event} not allowed in state #{@current_state}")
        end
      end

      # Look up the transition
      key = {@current_state, event}
      new_state = TRANSITIONS[key]?

      # If no transition defined, state remains the same
      new_state ||= @current_state

      # Generate warnings for certain transitions
      warnings = generate_warnings(event, new_state)

      @current_state = new_state
      {new_state, warnings}
    end

    # Check if an event is valid without transitioning
    def can_handle?(event : Event) : Bool
      allowed = ALLOWED_EVENTS[@current_state]?
      allowed ? allowed.includes?(event) : false
    end

    # Get the appropriate event for headers
    def self.headers_event(end_stream : Bool, sending : Bool) : Event
      if sending
        end_stream ? Event::SendHeadersEndStream : Event::SendHeaders
      else
        end_stream ? Event::ReceiveHeadersEndStream : Event::ReceiveHeaders
      end
    end

    # Get the appropriate event for data
    def self.data_event(end_stream : Bool, sending : Bool) : Event
      if sending
        end_stream ? Event::SendDataEndStream : Event::SendData
      else
        end_stream ? Event::ReceiveDataEndStream : Event::ReceiveData
      end
    end

    # Get the appropriate event for RST_STREAM
    def self.rst_stream_event(sending : Bool) : Event
      sending ? Event::SendRstStream : Event::ReceiveRstStream
    end

    private def generate_warnings(event : Event, new_state : StreamState) : Array(String)
      warnings = [] of String

      # Warn about trailers in certain states
      if (event == Event::SendHeaders || event == Event::ReceiveHeaders) &&
         (@current_state == StreamState::OPEN ||
         @current_state == StreamState::HALF_CLOSED_LOCAL ||
         @current_state == StreamState::HALF_CLOSED_REMOTE)
        warnings << "Headers in #{@current_state} state are likely trailers"
      end

      warnings
    end

    # Validate that a specific operation is allowed
    def validate_send_headers : Nil
      unless can_handle?(Event::SendHeaders) || can_handle?(Event::SendHeadersEndStream)
        if @current_state == StreamState::CLOSED
          raise StreamClosedError.new(@stream_id, "Cannot send headers on closed stream")
        else
          raise StreamError.new(@stream_id, ErrorCode::PROTOCOL_ERROR,
            "Cannot send headers in state #{@current_state}")
        end
      end
    end

    def validate_send_data : Nil
      unless can_handle?(Event::SendData) || can_handle?(Event::SendDataEndStream)
        if @current_state == StreamState::CLOSED || @current_state == StreamState::HALF_CLOSED_LOCAL
          raise StreamClosedError.new(@stream_id, "Cannot send data on closed stream")
        else
          raise ProtocolError.new("Cannot send data in state #{@current_state}")
        end
      end
    end

    def validate_receive_headers : Nil
      unless can_handle?(Event::ReceiveHeaders) || can_handle?(Event::ReceiveHeadersEndStream)
        if @current_state == StreamState::CLOSED
          raise StreamClosedError.new(@stream_id, "Cannot receive headers on closed stream")
        else
          raise ProtocolError.new("Cannot receive headers in state #{@current_state}")
        end
      end
    end

    def validate_receive_data : Nil
      unless can_handle?(Event::ReceiveData) || can_handle?(Event::ReceiveDataEndStream)
        if @current_state == StreamState::CLOSED || @current_state == StreamState::HALF_CLOSED_REMOTE
          raise StreamClosedError.new(@stream_id, "Cannot receive data on closed stream")
        elsif @current_state == StreamState::IDLE
          raise ProtocolError.new("Cannot receive data in IDLE state")
        else
          raise ProtocolError.new("Cannot receive data in state #{@current_state}")
        end
      end
    end
  end
end
