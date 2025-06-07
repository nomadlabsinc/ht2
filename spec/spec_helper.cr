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
