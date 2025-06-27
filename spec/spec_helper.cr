require "spec"
require "../src/ht2"
require "./test_helper"
require "./spec_cleanup_helper"
require "./test_timeout_helper"

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

# Mock bidirectional socket for testing
class MockBidirectionalSocket < IO
  getter? closed : Bool = false

  def initialize(@read_io : IO::Memory, @write_io : IO::Memory)
  end

  def read(slice : Bytes) : Int32
    raise IO::Error.new("Closed stream") if @closed
    @read_io.read(slice)
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("Closed stream") if @closed
    @write_io.write(slice)
  end

  def flush : Nil
    return if @closed
    @write_io.flush rescue nil
  end

  def close : Nil
    return if @closed
    @closed = true
    # Don't close the underlying IO objects - they may be used by tests
  end
end
