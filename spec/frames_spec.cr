require "./spec_helper"

describe HT2::Frame do
  describe "frame parsing and serialization" do
    it "parses frame header correctly" do
      # Create a test frame header
      bytes = Bytes.new(9)
      # Length: 16 (0x000010)
      bytes[0] = 0x00
      bytes[1] = 0x00
      bytes[2] = 0x10
      # Type: DATA (0x00)
      bytes[3] = 0x00
      # Flags: END_STREAM (0x01)
      bytes[4] = 0x01
      # Stream ID: 5 (0x00000005)
      bytes[5] = 0x00
      bytes[6] = 0x00
      bytes[7] = 0x00
      bytes[8] = 0x05

      length, type, flags, stream_id = HT2::Frame.parse_header(bytes)

      length.should eq(16)
      type.should eq(HT2::FrameType::DATA)
      flags.should eq(HT2::FrameFlags::END_STREAM)
      stream_id.should eq(5)
    end

    it "handles reserved bit in stream ID" do
      bytes = Bytes.new(9)
      bytes[0] = 0x00
      bytes[1] = 0x00
      bytes[2] = 0x00
      bytes[3] = 0x00
      bytes[4] = 0x00
      # Set reserved bit (0x80) and stream ID
      bytes[5] = 0x80 | 0x00
      bytes[6] = 0x00
      bytes[7] = 0x00
      bytes[8] = 0x05

      _, _, _, stream_id = HT2::Frame.parse_header(bytes)

      # Reserved bit should be ignored
      stream_id.should eq(5)
    end
  end
end

describe HT2::DataFrame do
  it "serializes and parses correctly" do
    data = "Hello, World!".to_slice
    frame = HT2::DataFrame.new(1_u32, data, HT2::FrameFlags::END_STREAM)

    assert_frame_roundtrip(frame)

    bytes = frame.to_bytes
    parsed = HT2::Frame.parse(bytes).as(HT2::DataFrame)

    parsed.data.should eq(data)
  end

  it "handles padding correctly" do
    data = "Test data".to_slice
    padding = 10_u8
    frame = HT2::DataFrame.new(1_u32, data, HT2::FrameFlags::None, padding)

    frame.flags.padded?.should be_true

    bytes = frame.to_bytes
    parsed = HT2::Frame.parse(bytes).as(HT2::DataFrame)

    parsed.data.should eq(data)
    parsed.padding.should eq(padding)
  end

  it "rejects DATA frame on stream 0" do
    expect_raises(HT2::ProtocolError) do
      HT2::DataFrame.new(0_u32, "test".to_slice)
    end
  end
end

describe HT2::HeadersFrame do
  it "serializes and parses correctly" do
    header_block = "test headers".to_slice
    frame = HT2::HeadersFrame.new(1_u32, header_block, HT2::FrameFlags::END_HEADERS)

    assert_frame_roundtrip(frame)

    bytes = frame.to_bytes
    parsed = HT2::Frame.parse(bytes).as(HT2::HeadersFrame)

    parsed.header_block.should eq(header_block)
  end

  it "handles priority correctly" do
    header_block = "headers".to_slice
    priority = HT2::PriorityData.new(3_u32, 15_u8, true)
    frame = HT2::HeadersFrame.new(1_u32, header_block,
      HT2::FrameFlags::END_HEADERS, 0_u8, priority)

    frame.flags.priority?.should be_true

    bytes = frame.to_bytes
    parsed = HT2::Frame.parse(bytes).as(HT2::HeadersFrame)

    parsed_priority = parsed.priority || raise "No priority"
    parsed_priority.stream_dependency.should eq(3)
    parsed_priority.weight.should eq(15)
    parsed_priority.exclusive.should be_true
  end
end

describe HT2::SettingsFrame do
  it "serializes and parses correctly" do
    settings = HT2::SettingsFrame::Settings.new
    settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE] = 32768_u32
    settings[HT2::SettingsParameter::MAX_FRAME_SIZE] = 32768_u32

    frame = HT2::SettingsFrame.new(settings: settings)

    assert_frame_roundtrip(frame)

    bytes = frame.to_bytes
    parsed = HT2::Frame.parse(bytes).as(HT2::SettingsFrame)

    parsed.settings.size.should eq(2)
    parsed.settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE].should eq(32768)
    parsed.settings[HT2::SettingsParameter::MAX_FRAME_SIZE].should eq(32768)
  end

  it "handles ACK correctly" do
    frame = HT2::SettingsFrame.new(HT2::FrameFlags::ACK)

    bytes = frame.to_bytes
    parsed = HT2::Frame.parse(bytes).as(HT2::SettingsFrame)

    parsed.flags.ack?.should be_true
    parsed.settings.empty?.should be_true
  end

  it "validates settings values" do
    settings = HT2::SettingsFrame::Settings.new
    settings[HT2::SettingsParameter::ENABLE_PUSH] = 2_u32 # Invalid

    frame = HT2::SettingsFrame.new(settings: settings)
    bytes = frame.to_bytes

    expect_raises(HT2::ConnectionError) do
      HT2::Frame.parse(bytes)
    end
  end
end

describe HT2::PingFrame do
  it "serializes and parses correctly" do
    data = Bytes.new(8) { |i| i.to_u8 }
    frame = HT2::PingFrame.new(data)

    assert_frame_roundtrip(frame)

    bytes = frame.to_bytes
    parsed = HT2::Frame.parse(bytes).as(HT2::PingFrame)

    parsed.opaque_data.should eq(data)
  end

  it "requires exactly 8 bytes of data" do
    expect_raises(HT2::ProtocolError) do
      HT2::PingFrame.new(Bytes.new(7))
    end

    expect_raises(HT2::ProtocolError) do
      HT2::PingFrame.new(Bytes.new(9))
    end
  end
end

describe HT2::GoAwayFrame do
  it "serializes and parses correctly" do
    frame = HT2::GoAwayFrame.new(42_u32, HT2::ErrorCode::PROTOCOL_ERROR,
      "debug info".to_slice)

    assert_frame_roundtrip(frame)

    bytes = frame.to_bytes
    parsed = HT2::Frame.parse(bytes).as(HT2::GoAwayFrame)

    parsed.last_stream_id.should eq(42)
    parsed.error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
    String.new(parsed.debug_data).should eq("debug info")
  end
end

describe HT2::WindowUpdateFrame do
  it "serializes and parses correctly" do
    frame = HT2::WindowUpdateFrame.new(1_u32, 65535_u32)

    assert_frame_roundtrip(frame)

    bytes = frame.to_bytes
    parsed = HT2::Frame.parse(bytes).as(HT2::WindowUpdateFrame)

    parsed.window_size_increment.should eq(65535)
  end

  it "rejects zero increment" do
    expect_raises(HT2::ProtocolError) do
      HT2::WindowUpdateFrame.new(1_u32, 0_u32)
    end
  end

  it "rejects too large increment" do
    expect_raises(HT2::ProtocolError) do
      HT2::WindowUpdateFrame.new(1_u32, 0x80000000_u32)
    end
  end
end

describe HT2::RstStreamFrame do
  it "serializes and parses correctly" do
    frame = HT2::RstStreamFrame.new(1_u32, HT2::ErrorCode::CANCEL)

    assert_frame_roundtrip(frame)

    bytes = frame.to_bytes
    parsed = HT2::Frame.parse(bytes).as(HT2::RstStreamFrame)

    parsed.error_code.should eq(HT2::ErrorCode::CANCEL)
  end
end
