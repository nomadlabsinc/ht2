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
  @read_buffer : Bytes # Use a simple Bytes array for the buffer
  @read_buffer_pos : Int32
  @read_buffer_size : Int32
  @write_channel : Channel(Bytes) # Channel to send data to the other side
  @read_io : IO::Memory?
  @write_io : IO::Memory?

  def initialize
    @read_buffer = Bytes.new(4096) # Initial buffer size
    @read_buffer_pos = 0
    @read_buffer_size = 0
    @write_channel = Channel(Bytes).new
    @read_io = nil
    @write_io = nil
  end

  def initialize(@read_io : IO::Memory, @write_io : IO::Memory)
    @read_buffer = Bytes.new(4096) # Initial buffer size  
    @read_buffer_pos = 0
    @read_buffer_size = 0
    @write_channel = Channel(Bytes).new
  end

  # This method is called by the other MockBidirectionalSocket's write method
  def receive_data(data : Bytes) : Nil
    # Ensure buffer has capacity for new data
    ensure_read_buffer_capacity(data.size)
    data.copy_to(@read_buffer[@read_buffer_size, data.size])
    @read_buffer_size += data.size
  end

  def read(slice : Bytes) : Int32
    puts "MockBidirectionalSocket read requested: #{slice.size} bytes, current buffer size: #{@read_buffer_size}, pos: #{@read_buffer_pos}"
    raise IO::Error.new("Closed stream") if @closed

    bytes_read = 0

    loop do
      # Read from internal buffer first
      available_in_buffer = @read_buffer_size - @read_buffer_pos
      if available_in_buffer > 0
        to_read = Math.min(slice.size - bytes_read, available_in_buffer)
        slice[bytes_read, to_read].copy_from(@read_buffer[@read_buffer_pos, to_read])
        @read_buffer_pos += to_read
        bytes_read += to_read

        # If slice is full, or buffer is exhausted, return
        return bytes_read if bytes_read == slice.size || @read_buffer_pos == @read_buffer_size
      end

      # If buffer is exhausted, try to get more data from channel
      if bytes_read < slice.size
        begin
          select
          when data = @write_channel.receive
            puts "MockBidirectionalSocket received data from channel: #{data.size} bytes, hex: #{data.hexstring}"
            # Append new data to buffer
            ensure_read_buffer_capacity(data.size)
            data.copy_to(@read_buffer[@read_buffer_size, data.size])
            @read_buffer_size += data.size
            # Shift remaining data to beginning if buffer is getting full
            if @read_buffer_pos > 0 && @read_buffer_size > @read_buffer.size / 2
              shift_read_buffer
            end
          when timeout(10.milliseconds)
            # No more data for now, return what we have
            return bytes_read
          end # end for select
        rescue Channel::ClosedError
          # Channel closed, no more data will arrive
          return bytes_read
        end # end for begin
      else
        return bytes_read # Slice is full
      end
    end # end for loop do
    puts "MockBidirectionalSocket read returning: #{bytes_read} bytes"
    bytes_read
  end

  def write(slice : Bytes) : Nil
    @write_channel.send(slice)
  end

  def close : Nil
    @closed = true
    @write_channel.close
  end

  private def ensure_read_buffer_capacity(needed : Int32) : Nil
    remaining_capacity = @read_buffer.size - @read_buffer_size
    if needed > remaining_capacity
      new_size = @read_buffer.size + needed + 4096 # Grow by needed + a chunk
      new_buffer = Bytes.new(new_size)
      @read_buffer[0, @read_buffer_size].copy_to(new_buffer) # Copy existing data
      @read_buffer = new_buffer
    end
  end

  private def shift_read_buffer : Nil
    if @read_buffer_pos > 0
      remaining = @read_buffer_size - @read_buffer_pos
      @read_buffer[0, remaining].copy_from(@read_buffer[@read_buffer_pos, remaining])
      @read_buffer_size = remaining
      @read_buffer_pos = 0
    end
  end
end
