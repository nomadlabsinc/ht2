require "./spec_helper"

describe HT2::BufferPool do
  it "acquires and releases buffers" do
    pool = HT2::BufferPool.new(max_pool_size: 10, max_buffer_size: 1024)

    buffer = pool.acquire(100)
    buffer.size.should eq 100

    pool.release(buffer)
    stats = pool.stats
    stats[:available].should eq 1
  end

  it "reuses buffers when possible" do
    pool = HT2::BufferPool.new(max_pool_size: 10, max_buffer_size: 1024)

    # Get a buffer and release it
    buffer1 = pool.acquire(100)
    buffer1_ptr = buffer1.to_unsafe
    pool.release(buffer1)

    # Get another buffer of same or smaller size
    buffer2 = pool.acquire(50)

    # Should get the same underlying buffer
    buffer2.to_unsafe.should eq buffer1_ptr
    buffer2.size.should eq 50
  end

  it "allocates new buffer when requested size exceeds max" do
    pool = HT2::BufferPool.new(max_pool_size: 10, max_buffer_size: 1024)

    large_buffer = pool.acquire(2048)
    large_buffer.size.should eq 2048

    pool.release(large_buffer)

    # Should not be added to pool
    stats = pool.stats
    stats[:available].should eq 0
  end

  it "respects max pool size" do
    pool = HT2::BufferPool.new(max_pool_size: 2, max_buffer_size: 1024)

    buffers = Array(Bytes).new
    3.times do |i|
      buffer = pool.acquire(100)
      buffers << buffer
    end

    buffers.each { |buf| pool.release(buf) }

    stats = pool.stats
    stats[:available].should eq 2
  end

  it "clears buffers before reuse" do
    pool = HT2::BufferPool.new(max_pool_size: 10, max_buffer_size: 1024)

    buffer1 = pool.acquire(100)
    buffer1.fill(0xFF_u8)
    pool.release(buffer1)

    buffer2 = pool.acquire(50)
    # First 50 bytes should be cleared
    buffer2.all? { |b| b == 0_u8 }.should be_true
  end

  it "handles concurrent access" do
    pool = HT2::BufferPool.new(max_pool_size: 100, max_buffer_size: 1024)

    done = Channel(Nil).new

    10.times do
      spawn do
        10.times do
          buffer = pool.acquire(rand(50..200))
          sleep rand(0.001..0.005).seconds
          pool.release(buffer)
        end
        done.send(nil)
      end
    end

    10.times { done.receive }

    stats = pool.stats
    stats[:available].should be > 0
    stats[:available].should be <= 100
  end

  it "can clear all buffers" do
    pool = HT2::BufferPool.new(max_pool_size: 10, max_buffer_size: 1024)

    # Acquire and release 5 different buffers
    buffers = Array(Bytes).new
    5.times do |i|
      buffer = pool.acquire(100 + i * 10) # Different sizes to avoid reuse
      buffers << buffer
    end

    buffers.each { |buf| pool.release(buf) }

    stats = pool.stats
    stats[:available].should eq 5

    pool.clear

    stats = pool.stats
    stats[:available].should eq 0
  end
end
