require "./spec_helper"

describe HT2::BufferedSocket do
  it "allows peeking without consuming data" do
    io = IO::Memory.new("Hello, World!")
    buffered = HT2::BufferedSocket.new(io)

    # Peek at first 5 bytes
    peeked = buffered.peek(5)
    peeked.should eq "Hello".to_slice

    # Read should still get the same data
    buffer = Bytes.new(5)
    bytes_read = buffered.read(buffer)
    bytes_read.should eq 5
    String.new(buffer).should eq "Hello"
  end

  it "handles peek larger than available data" do
    io = IO::Memory.new("Hi")
    buffered = HT2::BufferedSocket.new(io)

    peeked = buffered.peek(10)
    peeked.size.should eq 2
    String.new(peeked).should eq "Hi"
  end

  it "allows multiple peeks" do
    io = IO::Memory.new("Testing multiple peeks")
    buffered = HT2::BufferedSocket.new(io)

    # First peek
    peek1 = buffered.peek(7)
    String.new(peek1).should eq "Testing"

    # Second peek - should still see same data
    peek2 = buffered.peek(7)
    String.new(peek2).should eq "Testing"

    # Larger peek
    peek3 = buffered.peek(15)
    String.new(peek3).should eq "Testing multipl"
  end

  it "mixes peek and read operations" do
    io = IO::Memory.new("ABCDEFGHIJKLMNOP")
    buffered = HT2::BufferedSocket.new(io)

    # Peek first
    peeked = buffered.peek(3)
    String.new(peeked).should eq "ABC"

    # Read partial
    buffer = Bytes.new(2)
    buffered.read(buffer)
    String.new(buffer).should eq "AB"

    # Peek again - should see from position 2
    peeked = buffered.peek(3)
    String.new(peeked).should eq "CDE"

    # Read more
    buffer = Bytes.new(4)
    buffered.read(buffer)
    String.new(buffer).should eq "CDEF"
  end

  it "handles write operations" do
    io = IO::Memory.new
    buffered = HT2::BufferedSocket.new(io)

    buffered.write("Hello".to_slice)
    buffered.flush

    io.rewind
    io.gets_to_end.should eq "Hello"
  end

  it "handles close operations" do
    io = IO::Memory.new("data")
    buffered = HT2::BufferedSocket.new(io)

    buffered.closed?.should be_false
    buffered.close
    buffered.closed?.should be_true

    # Operations after close should not crash
    buffer = Bytes.new(10)
    buffered.read(buffer).should eq 0
  end

  it "resizes buffer when needed" do
    io = IO::Memory.new("A" * 2000)
    buffered = HT2::BufferedSocket.new(io, initial_buffer_size: 10)

    # Peek larger than initial buffer
    peeked = buffered.peek(1500)
    peeked.size.should eq 1500
    peeked.all? { |b| b == 'A'.ord }.should be_true
  end
end
