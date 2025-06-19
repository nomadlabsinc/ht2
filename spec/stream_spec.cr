require "./spec_helper"

# Mock connection for testing
class MockConnection < HT2::Connection
  getter sent_frames : Array(HT2::Frame)

  def initialize
    @socket = IO::Memory.new
    @is_server = true
    @streams = Hash(UInt32, HT2::Stream).new
    @local_settings = HT2::SettingsFrame::Settings.new
    @local_settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE] = 65535_u32
    @local_settings[HT2::SettingsParameter::HEADER_TABLE_SIZE] = 4096_u32
    @local_settings[HT2::SettingsParameter::ENABLE_PUSH] = 1_u32
    @local_settings[HT2::SettingsParameter::MAX_CONCURRENT_STREAMS] = 100_u32
    @local_settings[HT2::SettingsParameter::MAX_FRAME_SIZE] = 16384_u32
    @local_settings[HT2::SettingsParameter::MAX_HEADER_LIST_SIZE] = 8192_u32
    @remote_settings = HT2::SettingsFrame::Settings.new
    @remote_settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE] = 65535_u32
    @remote_settings[HT2::SettingsParameter::HEADER_TABLE_SIZE] = 4096_u32
    @remote_settings[HT2::SettingsParameter::ENABLE_PUSH] = 1_u32
    @remote_settings[HT2::SettingsParameter::MAX_CONCURRENT_STREAMS] = 100_u32
    @remote_settings[HT2::SettingsParameter::MAX_FRAME_SIZE] = 16384_u32
    @remote_settings[HT2::SettingsParameter::MAX_HEADER_LIST_SIZE] = 8192_u32
    @applied_settings = HT2::SettingsFrame::Settings.new
    @hpack_encoder = HT2::HPACK::Encoder.new
    @hpack_decoder = HT2::HPACK::Decoder.new(HT2::DEFAULT_HEADER_TABLE_SIZE, HT2::Security::MAX_HEADER_LIST_SIZE)
    @window_size = 65535_i64
    @last_stream_id = 0_u32
    @goaway_sent = false
    @goaway_received = false
    @sent_frames = Array(HT2::Frame).new
    @read_buffer = Bytes.new(16384)
    @frame_buffer = IO::Memory.new
    @continuation_stream_id = nil
    @continuation_headers = IO::Memory.new
    @continuation_end_stream = false
    @continuation_frame_count = 0_u32
    @ping_handlers = Hash(Bytes, Channel(Nil)).new
    @settings_ack_channel = Channel(Nil).new
    @pending_settings = [] of Channel(Nil)
    @closed = false
    @write_mutex = Mutex.new
    @total_streams_count = 0_u32
    @settings_rate_limiter = HT2::Security::RateLimiter.new(HT2::Security::MAX_SETTINGS_PER_SECOND)
    @ping_rate_limiter = HT2::Security::RateLimiter.new(HT2::Security::MAX_PING_PER_SECOND)
    @rst_rate_limiter = HT2::Security::RateLimiter.new(HT2::Security::MAX_RST_PER_SECOND)
    @priority_rate_limiter = HT2::Security::RateLimiter.new(HT2::Security::MAX_PRIORITY_PER_SECOND)
    @flow_controller = HT2::AdaptiveFlowControl.new(
      @local_settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE].to_i64,
      HT2::AdaptiveFlowControl::Strategy::DYNAMIC
    )
    @rapid_reset_protection = HT2::RapidResetProtection.new
    @connection_id = "mock-connection"
    @backpressure_manager = HT2::BackpressureManager.new
    @adaptive_buffer_manager = HT2::AdaptiveBufferManager.new
    @buffer_pool = HT2::BufferPool.new
    @frame_cache = HT2::FrameCache.new
    @metrics = HT2::ConnectionMetrics.new
    @performance_metrics = HT2::PerformanceMetrics.new
  end

  def send_frame(frame : HT2::Frame) : Nil
    @sent_frames << frame
  end
end

describe HT2::Stream do
  it "initializes with correct defaults" do
    connection = MockConnection.new
    stream = HT2::Stream.new(connection, 1_u32)

    stream.id.should eq(1)
    stream.state.should eq(HT2::StreamState::IDLE)
    stream.send_window_size.should eq(65535)
    stream.end_stream_sent?.should be_false
    stream.end_stream_received?.should be_false
  end

  describe "state transitions" do
    it "transitions from IDLE to OPEN on headers" do
      connection = MockConnection.new
      stream = HT2::Stream.new(connection, 1_u32)

      headers : Array(Tuple(String, String)) = [
        {":status", "200"},
        {"content-type", "text/plain"},
      ]

      stream.send_headers(headers, end_stream: false)
      stream.state.should eq(HT2::StreamState::OPEN)
    end

    it "transitions from IDLE to HALF_CLOSED_LOCAL on headers with END_STREAM" do
      connection = MockConnection.new
      stream = HT2::Stream.new(connection, 1_u32)

      headers : Array(Tuple(String, String)) = [
        {":status", "204"},
      ]

      stream.send_headers(headers, end_stream: true)
      stream.state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      stream.end_stream_sent?.should be_true
    end

    it "transitions from OPEN to HALF_CLOSED_LOCAL on data with END_STREAM" do
      connection = MockConnection.new
      stream = HT2::Stream.new(connection, 1_u32)

      # First send headers to open stream
      headers : Array(Tuple(String, String)) = [
        {":status", "200"},
      ]
      stream.send_headers(headers, end_stream: false)
      stream.state.should eq(HT2::StreamState::OPEN)

      # Then send data with END_STREAM
      data : Bytes = "test data".to_slice
      stream.send_data(data, end_stream: true)
      stream.state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
    end

    it "transitions to CLOSED from HALF_CLOSED states" do
      connection = MockConnection.new
      stream = HT2::Stream.new(connection, 1_u32)
      stream.state = HT2::StreamState::HALF_CLOSED_REMOTE

      headers : Array(Tuple(String, String)) = [
        {":status", "200"},
      ]
      stream.send_headers(headers, end_stream: true)
      stream.state.should eq(HT2::StreamState::CLOSED)
    end
  end

  describe "data flow control" do
    it "tracks window size for sent data" do
      connection = MockConnection.new
      stream = HT2::Stream.new(connection, 1_u32)
      stream.state = HT2::StreamState::OPEN

      initial_window : Int64 = stream.send_window_size
      data : Bytes = "test data".to_slice

      stream.send_data(data, end_stream: false)
      stream.send_window_size.should eq(initial_window - data.size)
    end

    it "rejects data larger than window" do
      connection = MockConnection.new
      stream = HT2::Stream.new(connection, 1_u32)
      stream.state = HT2::StreamState::OPEN
      stream.send_window_size = 10_i64

      large_data : Bytes = Bytes.new(11)

      expect_raises(HT2::StreamError) do
        stream.send_data(large_data, end_stream: false)
      end
    end

    it "updates window size on WINDOW_UPDATE" do
      connection = MockConnection.new
      stream = HT2::Stream.new(connection, 1_u32)

      initial_window : Int64 = stream.send_window_size
      increment : UInt32 = 1000_u32

      stream.update_send_window(increment.to_i32)
      stream.send_window_size.should eq(initial_window + increment)
    end
  end

  describe "error handling" do
    it "validates state for sending headers" do
      connection = MockConnection.new
      stream = HT2::Stream.new(connection, 1_u32)
      stream.state = HT2::StreamState::CLOSED

      headers : Array(Tuple(String, String)) = [
        {":status", "200"},
      ]

      expect_raises(HT2::StreamError) do
        stream.send_headers(headers)
      end
    end

    it "validates state for sending data" do
      connection = MockConnection.new
      stream = HT2::Stream.new(connection, 1_u32)
      stream.state = HT2::StreamState::IDLE

      data : Bytes = "test".to_slice

      expect_raises(HT2::ProtocolError) do
        stream.send_data(data)
      end
    end

    it "sends RST_STREAM on error" do
      connection = MockConnection.new
      stream = HT2::Stream.new(connection, 1_u32)

      stream.send_rst_stream(HT2::ErrorCode::INTERNAL_ERROR)
      stream.state.should eq(HT2::StreamState::CLOSED)

      connection.sent_frames.size.should eq(1)
      rst_frame = connection.sent_frames[0].as(HT2::RstStreamFrame)
      rst_frame.error_code.should eq(HT2::ErrorCode::INTERNAL_ERROR)
    end
  end

  describe "receiving data" do
    it "accumulates received data" do
      connection = MockConnection.new
      stream = HT2::Stream.new(connection, 1_u32)
      stream.state = HT2::StreamState::OPEN

      data1 : Bytes = "Hello ".to_slice
      data2 : Bytes = "World!".to_slice

      stream.receive_data(data1, end_stream: false)
      stream.receive_data(data2, end_stream: true)

      stream.data.to_s.should eq("Hello World!")
      stream.end_stream_received?.should be_true
    end
  end
end
