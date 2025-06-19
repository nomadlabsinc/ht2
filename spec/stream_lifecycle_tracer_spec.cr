require "./spec_helper"

describe HT2::StreamLifecycleTracer do
  describe "#initialize" do
    it "creates a tracer disabled by default" do
      tracer = HT2::StreamLifecycleTracer.new
      tracer.enabled?.should be_false
    end

    it "creates a tracer with specified enabled state" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      tracer.enabled?.should be_true
    end
  end

  describe "#enabled=" do
    it "enables and disables tracing" do
      tracer = HT2::StreamLifecycleTracer.new
      tracer.enabled = true
      tracer.enabled?.should be_true

      tracer.enabled = false
      tracer.enabled?.should be_false
    end
  end

  describe "#record_event" do
    it "does not record events when disabled" do
      tracer = HT2::StreamLifecycleTracer.new(false)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, 1_u32)
      tracer.active_streams.size.should eq(0)
    end

    it "records stream creation event" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, 1_u32, "Test stream")

      streams = tracer.active_streams
      streams.size.should eq(1)
      streams[0].stream_id.should eq(1_u32)
      streams[0].events.size.should eq(1)
      streams[0].events[0].event_type.should eq(HT2::StreamLifecycleTracer::EventType::CREATED)
    end

    it "records state change events" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, 1_u32)
      tracer.record_event(
        HT2::StreamLifecycleTracer::EventType::STATE_CHANGE,
        1_u32,
        "Headers sent",
        HT2::StreamState::IDLE,
        HT2::StreamState::OPEN
      )

      history = tracer.get_stream_history(1_u32)
      history.should_not be_nil
      history.try(&.events.size).should eq(2)

      state_event = history.try(&.events[1])
      state_event.should_not be_nil
      state_event.try(&.previous_state).should eq(HT2::StreamState::IDLE)
      state_event.try(&.new_state).should eq(HT2::StreamState::OPEN)
    end

    it "moves stream to closed list when closed" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, 1_u32)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CLOSED, 1_u32, "Stream completed")

      tracer.active_streams.size.should eq(0)
      tracer.closed_streams.size.should eq(1)
      tracer.closed_streams[0].stream_id.should eq(1_u32)
    end

    it "limits closed stream history" do
      tracer = HT2::StreamLifecycleTracer.new(true)

      # Create and close more than MAX_CLOSED_STREAMS
      (HT2::StreamLifecycleTracer::MAX_CLOSED_STREAMS + 10).times do |i|
        stream_id = (i + 1).to_u32
        tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, stream_id)
        tracer.record_event(HT2::StreamLifecycleTracer::EventType::CLOSED, stream_id)
      end

      tracer.closed_streams.size.should eq(HT2::StreamLifecycleTracer::MAX_CLOSED_STREAMS)
    end
  end

  describe "#get_stream_history" do
    it "returns history for active stream" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, 1_u32)

      history = tracer.get_stream_history(1_u32)
      history.should_not be_nil
      history.try(&.stream_id).should eq(1_u32)
    end

    it "returns history for closed stream" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, 1_u32)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CLOSED, 1_u32)

      history = tracer.get_stream_history(1_u32)
      history.should_not be_nil
      history.try(&.closed?).should be_true
    end

    it "returns nil for unknown stream" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      history = tracer.get_stream_history(999_u32)
      history.should be_nil
    end
  end

  describe "#generate_report" do
    it "generates a report with active and closed streams" do
      tracer = HT2::StreamLifecycleTracer.new(true)

      # Create active stream
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, 1_u32)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::HEADERS_SENT, 1_u32)

      # Create closed stream
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, 3_u32)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CLOSED, 3_u32)

      report = tracer.generate_report
      report.should contain("Stream Lifecycle Report")
      report.should contain("Active Streams (1)")
      report.should contain("Stream 1:")
      report.should contain("Recently Closed Streams (1)")
      report.should contain("Stream 3:")
      report.should contain("[CLOSED]")
    end
  end

  describe "#get_stream_trace" do
    it "returns detailed trace for a stream" do
      tracer = HT2::StreamLifecycleTracer.new(true)

      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, 1_u32)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::HEADERS_SENT, 1_u32, "GET /test")
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::DATA_SENT, 1_u32, "1024 bytes")
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CLOSED, 1_u32)

      trace = tracer.get_stream_trace(1_u32)
      trace.should contain("Stream 1 Lifecycle Trace")
      trace.should contain("CREATED")
      trace.should contain("HEADERS_SENT")
      trace.should contain("DATA_SENT")
      trace.should contain("CLOSED")
      trace.should contain("GET /test")
      trace.should contain("1024 bytes")
    end

    it "returns not found message for unknown stream" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      trace = tracer.get_stream_trace(999_u32)
      trace.should eq("Stream 999 not found")
    end
  end

  describe "#clear" do
    it "clears all stream histories" do
      tracer = HT2::StreamLifecycleTracer.new(true)

      # Add some streams
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, 1_u32)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CREATED, 3_u32)
      tracer.record_event(HT2::StreamLifecycleTracer::EventType::CLOSED, 3_u32)

      tracer.active_streams.size.should eq(1)
      tracer.closed_streams.size.should eq(1)

      tracer.clear

      tracer.active_streams.size.should eq(0)
      tracer.closed_streams.size.should eq(0)
    end
  end

  describe "Event formatting" do
    it "formats state change events correctly" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      event = HT2::StreamLifecycleTracer::Event.new(
        HT2::StreamLifecycleTracer::EventType::STATE_CHANGE,
        1_u32,
        Time.utc(2024, 1, 1, 12, 0, 0),
        "Test transition",
        HT2::StreamState::IDLE,
        HT2::StreamState::OPEN
      )

      event_str = event.to_s
      event_str.should contain("Stream 1: STATE_CHANGE")
      event_str.should contain("(IDLE -> OPEN)")
      event_str.should contain("Test transition")
    end

    it "formats regular events correctly" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      event = HT2::StreamLifecycleTracer::Event.new(
        HT2::StreamLifecycleTracer::EventType::DATA_SENT,
        1_u32,
        Time.utc(2024, 1, 1, 12, 0, 0),
        "Sent 1024 bytes"
      )

      event_str = event.to_s
      event_str.should contain("Stream 1: DATA_SENT")
      event_str.should contain("Sent 1024 bytes")
    end
  end

  describe "StreamHistory" do
    it "tracks duration correctly" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      history = HT2::StreamLifecycleTracer::StreamHistory.new(1_u32, Time.utc(2024, 1, 1, 12, 0, 0))

      # Add event 5 seconds later
      later_event = HT2::StreamLifecycleTracer::Event.new(
        HT2::StreamLifecycleTracer::EventType::CLOSED,
        1_u32,
        Time.utc(2024, 1, 1, 12, 0, 5)
      )
      history.add_event(later_event)

      history.duration.should eq(5.seconds)
    end

    it "filters state transitions correctly" do
      tracer = HT2::StreamLifecycleTracer.new(true)
      history = HT2::StreamLifecycleTracer::StreamHistory.new(1_u32)

      # Add various events
      history.add_event(HT2::StreamLifecycleTracer::Event.new(
        HT2::StreamLifecycleTracer::EventType::HEADERS_SENT, 1_u32
      ))
      history.add_event(HT2::StreamLifecycleTracer::Event.new(
        HT2::StreamLifecycleTracer::EventType::STATE_CHANGE, 1_u32
      ))
      history.add_event(HT2::StreamLifecycleTracer::Event.new(
        HT2::StreamLifecycleTracer::EventType::DATA_SENT, 1_u32
      ))
      history.add_event(HT2::StreamLifecycleTracer::Event.new(
        HT2::StreamLifecycleTracer::EventType::STATE_CHANGE, 1_u32
      ))

      transitions = history.state_transitions
      transitions.size.should eq(2)
      transitions.all? { |e| e.event_type == HT2::StreamLifecycleTracer::EventType::STATE_CHANGE }.should be_true
    end
  end
end
