require "spec"
require "../src/ht2"

# Helper methods for tests
def create_test_bytes(size : Int32) : Bytes
  bytes = Bytes.new(size)
  size.times { |i| bytes[i] = (i % 256).to_u8 }
  bytes
end

def assert_frame_roundtrip(frame : HT2::Frame)
  bytes = frame.to_bytes
  parsed = HT2::Frame.parse(bytes)

  parsed.class.should eq(frame.class)
  parsed.stream_id.should eq(frame.stream_id)
  parsed.flags.should eq(frame.flags)
end

# Test helper to expose private methods for security testing
class HT2::Connection
  # Expose instance variables for testing
  property continuation_headers : IO::Memory
  property continuation_stream_id : UInt32?
  property window_size : Int64
  property total_streams_count : UInt32
  property ping_handlers : Hash(Bytes, Channel(Nil))
  property ping_rate_limiter : HT2::Security::RateLimiter
  property local_settings : HT2::SettingsFrame::Settings
  property remote_settings : HT2::SettingsFrame::Settings

  # Make private methods public for testing
  def test_handle_continuation_frame(frame : ContinuationFrame)
    handle_continuation_frame(frame)
  end

  def test_handle_ping_frame(frame : PingFrame)
    handle_ping_frame(frame)
  end

  def test_handle_window_update_frame(frame : WindowUpdateFrame)
    handle_window_update_frame(frame)
  end

  def test_handle_priority_frame(frame : PriorityFrame)
    handle_priority_frame(frame)
  end

  def test_handle_rst_stream_frame(frame : RstStreamFrame)
    handle_rst_stream_frame(frame)
  end

  def test_get_or_create_stream(stream_id : UInt32) : Stream
    get_or_create_stream(stream_id)
  end
end
