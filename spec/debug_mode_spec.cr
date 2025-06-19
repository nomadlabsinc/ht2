require "./spec_helper"
require "../src/ht2/debug_mode"

describe HT2::DebugMode do
  before_each do
    HT2::DebugMode.disable
  end

  after_each do
    HT2::DebugMode.disable
  end

  describe ".enable" do
    it "enables debug mode with default config" do
      HT2::DebugMode.enable
      HT2::DebugMode.enabled?.should be_true
    end

    it "enables debug mode with custom config" do
      config = HT2::DebugMode::Config.new(
        frame_data_limit: 128,
        frame_logging: false,
        log_level: Log::Severity::Trace
      )
      HT2::DebugMode.enable(config)
      HT2::DebugMode.enabled?.should be_true
      HT2::DebugMode.config.frame_data_limit.should eq(128)
      HT2::DebugMode.config.frame_logging?.should be_false
      HT2::DebugMode.config.log_level.should eq(Log::Severity::Trace)
    end
  end

  describe ".disable" do
    it "disables debug mode" do
      HT2::DebugMode.enable
      HT2::DebugMode.enabled?.should be_true
      HT2::DebugMode.disable
      HT2::DebugMode.enabled?.should be_false
    end
  end

  describe ".log_frame" do
    it "does not log when disabled" do
      # Just verify the method can be called when disabled
      frame = HT2::DataFrame.new(1_u32, "test data".to_slice)
      HT2::DebugMode.log_frame("conn1", HT2::DebugMode::Direction::Inbound, frame)
      # Should not raise any errors
    end

    it "logs frames when enabled" do
      HT2::DebugMode.enable

      # Test various frame types to ensure formatting works
      data_frame = HT2::DataFrame.new(1_u32, "test data".to_slice)
      HT2::DebugMode.log_frame("conn1", HT2::DebugMode::Direction::Inbound, data_frame)

      flags = HT2::FrameFlags::END_STREAM | HT2::FrameFlags::END_HEADERS
      headers_frame = HT2::HeadersFrame.new(
        stream_id: 3_u32,
        header_block: "header data".to_slice,
        flags: flags
      )
      HT2::DebugMode.log_frame("conn1", HT2::DebugMode::Direction::Outbound, headers_frame)

      settings = HT2::SettingsFrame::Settings.new
      settings[HT2::SettingsParameter::ENABLE_PUSH] = 0_u32
      settings_frame = HT2::SettingsFrame.new(settings: settings)
      HT2::DebugMode.log_frame("conn1", HT2::DebugMode::Direction::Inbound, settings_frame)

      # Should not raise any errors
    end

    it "respects frame_logging configuration" do
      config = HT2::DebugMode::Config.new(frame_logging: false)
      HT2::DebugMode.enable(config)

      frame = HT2::DataFrame.new(1_u32, "test".to_slice)
      HT2::DebugMode.log_frame("conn1", HT2::DebugMode::Direction::Inbound, frame)
      # Should not raise any errors
    end

    it "handles large data with truncation" do
      config = HT2::DebugMode::Config.new(frame_data_limit: 10)
      HT2::DebugMode.enable(config)

      large_data = "a" * 100
      frame = HT2::DataFrame.new(1_u32, large_data.to_slice)
      HT2::DebugMode.log_frame("conn1", HT2::DebugMode::Direction::Outbound, frame)
      # Should not raise any errors
    end
  end

  describe ".log_raw_frame" do
    it "logs raw frame bytes at trace level" do
      config = HT2::DebugMode::Config.new(log_level: Log::Severity::Trace)
      HT2::DebugMode.enable(config)

      raw_bytes = Bytes[0, 0, 5, 0, 0, 0, 0, 0, 1, 72, 101, 108, 108, 111]
      HT2::DebugMode.log_raw_frame("conn1", HT2::DebugMode::Direction::Inbound, raw_bytes)
      # Should not raise any errors
    end

    it "handles large byte arrays" do
      config = HT2::DebugMode::Config.new(log_level: Log::Severity::Trace)
      HT2::DebugMode.enable(config)

      large_bytes = Bytes.new(100) { |i| i.to_u8 }
      HT2::DebugMode.log_raw_frame("conn1", HT2::DebugMode::Direction::Outbound, large_bytes)
      # Should not raise any errors
    end
  end
end
