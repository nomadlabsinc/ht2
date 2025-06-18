require "../spec_helper"

describe HT2::BackpressureManager do
  describe "#initialize" do
    it "creates manager with default settings" do
      manager = HT2::BackpressureManager.new
      manager.max_write_buffer.should eq HT2::BackpressureManager::DEFAULT_MAX_WRITE_BUFFER
      manager.high_watermark.should eq HT2::BackpressureManager::DEFAULT_HIGH_WATERMARK
      manager.low_watermark.should eq HT2::BackpressureManager::DEFAULT_LOW_WATERMARK
    end

    it "creates manager with custom settings" do
      manager = HT2::BackpressureManager.new(
        high_watermark: 0.9,
        low_watermark: 0.6,
        max_write_buffer: 2048
      )
      manager.max_write_buffer.should eq 2048
      manager.high_watermark.should eq 0.9
      manager.low_watermark.should eq 0.6
    end
  end

  describe "#track_write and #complete_write" do
    it "tracks pending writes" do
      manager = HT2::BackpressureManager.new

      manager.track_write(1000_i64, 1_u32)
      metrics = manager.connection_metrics
      metrics[:pending_bytes].should eq 1000
      metrics[:pending_frames].should eq 1

      manager.complete_write(500_i64, 1_u32)
      metrics = manager.connection_metrics
      metrics[:pending_bytes].should eq 500
      metrics[:pending_frames].should eq 0
    end

    it "tracks stream-specific pressure" do
      manager = HT2::BackpressureManager.new(max_write_buffer: 10000)

      manager.track_write(1000_i64, 1_u32)
      manager.track_write(2000_i64, 2_u32)

      # Check connection metrics first
      metrics = manager.connection_metrics
      metrics[:pending_bytes].should eq 3000

      # Stream 1: 1000 bytes / (10000/4) = 1000/2500 = 0.4
      pressure1 = manager.stream_pressure(1_u32)
      pressure1.should be_close(0.4, 0.001)

      # Stream 2: 2000 bytes / (10000/4) = 2000/2500 = 0.8
      pressure2 = manager.stream_pressure(2_u32)
      pressure2.should be_close(0.8, 0.001)

      manager.complete_write(1000_i64, 1_u32)
      manager.stream_pressure(1_u32).should eq 0.0
    end
  end

  describe "#should_pause? and #should_resume?" do
    it "triggers pause at high watermark" do
      manager = HT2::BackpressureManager.new(max_write_buffer: 1000)

      manager.should_pause?.should be_false
      manager.track_write(700_i64, nil)
      manager.should_pause?.should be_false

      manager.track_write(200_i64, nil)
      manager.should_pause?.should be_true
    end

    it "triggers resume at low watermark" do
      manager = HT2::BackpressureManager.new(max_write_buffer: 1000)

      manager.track_write(900_i64, nil)
      manager.should_pause?.should be_true
      manager.should_resume?.should be_false

      manager.complete_write(500_i64, nil)
      manager.should_pause?.should be_false
      manager.should_resume?.should be_true
    end
  end

  describe "#wait_for_capacity" do
    it "returns immediately when not paused" do
      manager = HT2::BackpressureManager.new

      start_time = Time.utc
      result = manager.wait_for_capacity(1.second)
      end_time = Time.utc

      result.should be_true
      (end_time - start_time).should be < 100.milliseconds
    end

    it "waits when paused and times out" do
      manager = HT2::BackpressureManager.new(max_write_buffer: 1000)
      manager.track_write(900_i64, nil)

      start_time = Time.utc
      result = manager.wait_for_capacity(100.milliseconds)
      end_time = Time.utc

      result.should be_false
      (end_time - start_time).should be >= 100.milliseconds
    end
  end

  describe "callbacks" do
    it "triggers pause and resume callbacks" do
      manager = HT2::BackpressureManager.new(max_write_buffer: 1000)

      pause_called = false
      resume_called = false

      manager.on_pause { pause_called = true }
      manager.on_resume { resume_called = true }

      manager.track_write(900_i64, nil)
      pause_called.should be_true
      resume_called.should be_false

      pause_called = false
      manager.complete_write(500_i64, nil)
      pause_called.should be_false
      resume_called.should be_true
    end
  end

  describe "WritePressure" do
    it "tracks stalls" do
      pressure = HT2::BackpressureManager::WritePressure.new

      pressure.stall_count.should eq 0
      pressure.last_stall.should be_nil

      pressure.record_stall
      pressure.stall_count.should eq 1
      pressure.last_stall.should_not be_nil
    end

    it "calculates pressure ratio" do
      pressure = HT2::BackpressureManager::WritePressure.new

      pressure.add_pending(500_i64, 5)
      pressure.pressure_ratio(1000_i64).should eq 0.5
      pressure.high_pressure?(1000_i64, 0.8).should be_false

      pressure.add_pending(400_i64, 4)
      pressure.pressure_ratio(1000_i64).should eq 0.9
      pressure.high_pressure?(1000_i64, 0.8).should be_true
    end
  end
end
