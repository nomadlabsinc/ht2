require "./spec_helper"

describe HT2::ConnectionMetrics do
  it "initializes with zero values" do
    metrics = HT2::ConnectionMetrics.new

    snapshot = metrics.snapshot
    snapshot[:streams][:created].should eq 0
    snapshot[:streams][:closed].should eq 0
    snapshot[:streams][:current].should eq 0
    snapshot[:streams][:max_concurrent].should eq 0
    snapshot[:bytes][:sent].should eq 0
    snapshot[:bytes][:received].should eq 0
    snapshot[:frames][:sent][:total].should eq 0
    snapshot[:frames][:received][:total].should eq 0
    snapshot[:errors][:sent][:total].should eq 0
    snapshot[:errors][:received][:total].should eq 0
    snapshot[:flow_control][:stalls].should eq 0
    snapshot[:state][:goaway_sent].should be_false
    snapshot[:state][:goaway_received].should be_false
  end

  it "tracks frame counters correctly" do
    metrics = HT2::ConnectionMetrics.new

    # Send various frame types
    metrics.record_frame_sent(HT2::DataFrame.new(1, Bytes.new(100)))
    metrics.record_frame_sent(HT2::HeadersFrame.new(3, Bytes.new(50)))
    metrics.record_frame_sent(HT2::PingFrame.new(Bytes.new(8)))
    metrics.record_frame_sent(HT2::SettingsFrame.new)

    # Receive various frame types
    metrics.record_frame_received(HT2::DataFrame.new(2, Bytes.new(200)))
    metrics.record_frame_received(HT2::WindowUpdateFrame.new(0, 1000))
    metrics.record_frame_received(HT2::RstStreamFrame.new(4, HT2::ErrorCode::CANCEL))

    snapshot = metrics.snapshot
    snapshot[:frames][:sent][:total].should eq 4
    snapshot[:frames][:sent][:data].should eq 1
    snapshot[:frames][:sent][:headers].should eq 1
    snapshot[:frames][:sent][:ping].should eq 1
    snapshot[:frames][:sent][:settings].should eq 1

    snapshot[:frames][:received][:total].should eq 3
    snapshot[:frames][:received][:data].should eq 1
    snapshot[:frames][:received][:window_update].should eq 1
    snapshot[:frames][:received][:rst_stream].should eq 1
  end

  it "tracks byte counters correctly" do
    metrics = HT2::ConnectionMetrics.new

    # Track bytes sent
    data_frame = HT2::DataFrame.new(1, Bytes.new(100))
    metrics.record_frame_sent(data_frame)
    metrics.record_bytes_sent(109) # Frame header + data

    # Track bytes received
    data_frame2 = HT2::DataFrame.new(2, Bytes.new(200))
    metrics.record_frame_received(data_frame2)
    metrics.record_bytes_received(209) # Frame header + data

    # Track non-frame bytes (preface)
    metrics.record_bytes_sent(24) # CONNECTION_PREFACE size

    snapshot = metrics.snapshot
    snapshot[:bytes][:sent].should eq 233     # 100 (data) + 109 (frame) + 24 (preface)
    snapshot[:bytes][:received].should eq 409 # 200 (data) + 209 (frame)
  end

  it "tracks stream lifecycle" do
    metrics = HT2::ConnectionMetrics.new

    # Create streams
    metrics.record_stream_created
    metrics.record_stream_created
    metrics.record_stream_created

    snapshot = metrics.snapshot
    snapshot[:streams][:created].should eq 3
    snapshot[:streams][:current].should eq 3
    snapshot[:streams][:max_concurrent].should eq 3

    # Close one stream
    metrics.record_stream_closed

    snapshot = metrics.snapshot
    snapshot[:streams][:closed].should eq 1
    snapshot[:streams][:current].should eq 2
    snapshot[:streams][:max_concurrent].should eq 3 # Should not decrease

    # Create more streams
    metrics.record_stream_created
    metrics.record_stream_created

    snapshot = metrics.snapshot
    snapshot[:streams][:created].should eq 5
    snapshot[:streams][:current].should eq 4
    snapshot[:streams][:max_concurrent].should eq 4 # New max
  end

  it "tracks error counters" do
    metrics = HT2::ConnectionMetrics.new

    # Send errors
    metrics.record_frame_sent(HT2::RstStreamFrame.new(1, HT2::ErrorCode::CANCEL))
    metrics.record_frame_sent(HT2::RstStreamFrame.new(3, HT2::ErrorCode::FLOW_CONTROL_ERROR))
    metrics.record_frame_sent(HT2::GoAwayFrame.new(5, HT2::ErrorCode::PROTOCOL_ERROR, Bytes.new(0)))

    # Receive errors
    metrics.record_frame_received(HT2::RstStreamFrame.new(2, HT2::ErrorCode::INTERNAL_ERROR))
    metrics.record_frame_received(HT2::GoAwayFrame.new(0, HT2::ErrorCode::ENHANCE_YOUR_CALM, Bytes.new(0)))

    snapshot = metrics.snapshot
    snapshot[:errors][:sent][:total].should eq 3
    snapshot[:errors][:sent][:cancel].should eq 1
    snapshot[:errors][:sent][:flow_control].should eq 1
    snapshot[:errors][:sent][:protocol].should eq 1

    snapshot[:errors][:received][:total].should eq 2
    snapshot[:errors][:received][:internal].should eq 1
    snapshot[:errors][:received][:enhance_your_calm].should eq 1
  end

  it "tracks flow control events" do
    metrics = HT2::ConnectionMetrics.new

    # Record flow control stalls
    metrics.record_flow_control_stall
    metrics.record_flow_control_stall

    # Track window updates
    metrics.record_frame_sent(HT2::WindowUpdateFrame.new(0, 1000))
    metrics.record_frame_sent(HT2::WindowUpdateFrame.new(1, 500))
    metrics.record_frame_received(HT2::WindowUpdateFrame.new(0, 2000))

    snapshot = metrics.snapshot
    snapshot[:flow_control][:stalls].should eq 2
    snapshot[:flow_control][:window_updates_sent].should eq 2
    snapshot[:flow_control][:window_updates_received].should eq 1
  end

  it "tracks GOAWAY state" do
    metrics = HT2::ConnectionMetrics.new

    snapshot = metrics.snapshot
    snapshot[:state][:goaway_sent].should be_false
    snapshot[:state][:goaway_received].should be_false

    # Send GOAWAY
    metrics.record_frame_sent(HT2::GoAwayFrame.new(0, HT2::ErrorCode::NO_ERROR, Bytes.new(0)))

    snapshot = metrics.snapshot
    snapshot[:state][:goaway_sent].should be_true
    snapshot[:state][:goaway_received].should be_false

    # Receive GOAWAY
    metrics.record_frame_received(HT2::GoAwayFrame.new(0, HT2::ErrorCode::NO_ERROR, Bytes.new(0)))

    snapshot = metrics.snapshot
    snapshot[:state][:goaway_sent].should be_true
    snapshot[:state][:goaway_received].should be_true
  end

  it "tracks timing metrics" do
    metrics = HT2::ConnectionMetrics.new

    # Let some time pass
    sleep 0.1.seconds

    snapshot = metrics.snapshot
    snapshot[:uptime_seconds].should be > 0.09
    snapshot[:uptime_seconds].should be < 0.2

    # Activity should update last_activity_at
    initial_idle = snapshot[:idle_seconds]
    metrics.record_stream_created

    snapshot = metrics.snapshot
    snapshot[:idle_seconds].should be < initial_idle
  end

  it "handles concurrent access safely" do
    metrics = HT2::ConnectionMetrics.new
    done = Channel(Nil).new

    # Spawn multiple fibers to update metrics concurrently
    10.times do |i|
      spawn do
        100.times do
          case i % 5
          when 0
            metrics.record_stream_created
          when 1
            metrics.record_stream_closed
          when 2
            metrics.record_frame_sent(HT2::DataFrame.new(1, Bytes.new(10)))
          when 3
            metrics.record_frame_received(HT2::PingFrame.new(Bytes.new(8)))
          when 4
            metrics.record_flow_control_stall
          end
        end
        done.send(nil)
      end
    end

    # Wait for all fibers to complete
    10.times { done.receive }

    # Verify metrics are consistent
    snapshot = metrics.snapshot
    snapshot[:streams][:created].should eq 200 # 2 fibers * 100 times
    snapshot[:streams][:closed].should eq 200  # 2 fibers * 100 times
    snapshot[:streams][:current].should eq 0   # Equal creates and closes
    snapshot[:frames][:sent][:data].should eq 200
    snapshot[:frames][:received][:ping].should eq 200
    snapshot[:flow_control][:stalls].should eq 200
  end

  it "provides comprehensive snapshot" do
    metrics = HT2::ConnectionMetrics.new

    # Generate some activity
    metrics.record_stream_created
    metrics.record_frame_sent(HT2::DataFrame.new(1, Bytes.new(100)))
    metrics.record_frame_received(HT2::HeadersFrame.new(1, Bytes.new(50)))
    metrics.record_bytes_sent(109)
    metrics.record_bytes_received(59)

    snapshot = metrics.snapshot

    # Verify all fields are present
    snapshot.has_key?(:started_at).should be_true
    snapshot.has_key?(:uptime_seconds).should be_true
    snapshot.has_key?(:idle_seconds).should be_true
    snapshot.has_key?(:streams).should be_true
    snapshot.has_key?(:bytes).should be_true
    snapshot.has_key?(:frames).should be_true
    snapshot.has_key?(:errors).should be_true
    snapshot.has_key?(:flow_control).should be_true
    snapshot.has_key?(:state).should be_true

    # Verify nested structures
    snapshot[:streams].has_key?(:created).should be_true
    snapshot[:frames][:sent].has_key?(:total).should be_true
    snapshot[:errors][:received].has_key?(:protocol).should be_true
  end
end
