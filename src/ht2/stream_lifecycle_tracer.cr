require "./stream"

module HT2
  # Tracks detailed stream lifecycle events for debugging and observability
  class StreamLifecycleTracer
    # Stream lifecycle event types
    enum EventType
      CREATED
      STATE_CHANGE
      HEADERS_SENT
      HEADERS_RECEIVED
      DATA_SENT
      DATA_RECEIVED
      RST_SENT
      RST_RECEIVED
      PRIORITY_UPDATED
      WINDOW_UPDATE_SENT
      WINDOW_UPDATE_RECEIVED
      FLOW_CONTROL_STALL
      FLOW_CONTROL_RESUME
      CLOSED
      ERROR
    end

    # Represents a single stream lifecycle event
    struct Event
      getter event_type : EventType
      getter previous_state : StreamState?
      getter new_state : StreamState?
      getter stream_id : UInt32
      getter timestamp : Time
      getter details : String?

      def initialize(@event_type : EventType, @stream_id : UInt32, @timestamp : Time = Time.utc,
                     @details : String? = nil, @previous_state : StreamState? = nil,
                     @new_state : StreamState? = nil)
      end

      def to_s(io : IO) : Nil
        io << "[#{timestamp.to_s("%H:%M:%S.%6N")}] Stream #{stream_id}: #{event_type}"
        if previous_state && new_state
          io << " (#{previous_state} -> #{new_state})"
        end
        io << " - #{details}" if details
      end
    end

    # Stores events for a single stream
    class StreamHistory
      getter created_at : Time
      getter events : Array(Event)
      getter stream_id : UInt32

      def initialize(@stream_id : UInt32, @created_at : Time = Time.utc)
        @events = Array(Event).new
        @events << Event.new(EventType::CREATED, stream_id, created_at)
      end

      def add_event(event : Event) : Nil
        @events << event
      end

      def closed? : Bool
        @events.any? { |e| e.event_type == EventType::CLOSED }
      end

      def duration : Time::Span
        return Time::Span.zero if @events.empty?
        last_event = @events.last
        last_event.timestamp - created_at
      end

      def state_transitions : Array(Event)
        @events.select { |e| e.event_type == EventType::STATE_CHANGE }
      end
    end

    # Maximum number of closed stream histories to retain
    MAX_CLOSED_STREAMS = 1000

    @mutex = Mutex.new
    @active_streams = Hash(UInt32, StreamHistory).new
    @closed_streams = Array(StreamHistory).new
    @enabled = false

    def initialize(@enabled : Bool = false)
    end

    # Enable or disable tracing
    def enabled=(value : Bool) : Nil
      @mutex.synchronize { @enabled = value }
    end

    def enabled? : Bool
      @mutex.synchronize { @enabled }
    end

    # Record a stream event
    def record_event(event_type : EventType, stream_id : UInt32, details : String? = nil,
                     previous_state : StreamState? = nil, new_state : StreamState? = nil) : Nil
      return unless enabled?

      event = Event.new(
        event_type: event_type,
        stream_id: stream_id,
        details: details,
        previous_state: previous_state,
        new_state: new_state
      )

      @mutex.synchronize do
        if event_type == EventType::CREATED
          @active_streams[stream_id] = StreamHistory.new(stream_id)
        elsif history = @active_streams[stream_id]?
          history.add_event(event)

          if event_type == EventType::CLOSED
            @active_streams.delete(stream_id)
            @closed_streams << history
            trim_closed_streams
          end
        end
      end
    end

    # Get history for a specific stream
    def get_stream_history(stream_id : UInt32) : StreamHistory?
      @mutex.synchronize do
        @active_streams[stream_id]? || @closed_streams.find { |history| history.stream_id == stream_id }
      end
    end

    # Get all active stream histories
    def active_streams : Array(StreamHistory)
      @mutex.synchronize { @active_streams.values }
    end

    # Get closed stream histories (most recent first)
    def closed_streams : Array(StreamHistory)
      @mutex.synchronize { @closed_streams.reverse }
    end

    # Generate a summary report
    def generate_report : String
      String.build do |io|
        @mutex.synchronize do
          io << "=== Stream Lifecycle Report ===\n\n"

          io << "Active Streams (#{@active_streams.size}):\n"
          @active_streams.each_value do |history|
            io << format_stream_summary(history)
            io << "\n"
          end

          io << "\nRecently Closed Streams (#{@closed_streams.size}):\n"
          @closed_streams.last(10).reverse_each do |history|
            io << format_stream_summary(history)
            io << "\n"
          end
        end
      end
    end

    # Get detailed trace for a specific stream
    def get_stream_trace(stream_id : UInt32) : String
      history = get_stream_history(stream_id)
      return "Stream #{stream_id} not found" unless history

      String.build do |io|
        io << "=== Stream #{stream_id} Lifecycle Trace ===\n"
        io << "Created: #{history.created_at}\n"
        io << "Duration: #{history.duration.total_seconds.round(3)}s\n"
        io << "Events (#{history.events.size}):\n\n"

        history.events.each do |event|
          io << "  #{event}\n"
        end
      end
    end

    # Clear all history
    def clear : Nil
      @mutex.synchronize do
        @active_streams.clear
        @closed_streams.clear
      end
    end

    private def trim_closed_streams : Nil
      excess = @closed_streams.size - MAX_CLOSED_STREAMS
      @closed_streams.shift(excess) if excess > 0
    end

    private def format_stream_summary(history : StreamHistory) : String
      String.build do |io|
        io << "  Stream #{history.stream_id}: "
        io << "Created #{history.created_at.to_s("%H:%M:%S")}, "
        io << "Duration: #{history.duration.total_seconds.round(3)}s, "
        io << "Events: #{history.events.size}, "
        io << "State transitions: #{history.state_transitions.size}"
        io << " [CLOSED]" if history.closed?
      end
    end
  end
end
