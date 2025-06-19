require "benchmark"
require "../src/ht2"

# Helper to measure memory allocations
def measure_memory(&)
  GC.collect
  before_heap = GC.stats.heap_size
  start_time = Time.monotonic

  yield

  end_time = Time.monotonic
  GC.collect
  after_heap = GC.stats.heap_size

  {
    heap_size_delta: after_heap - before_heap,
    duration:        end_time - start_time,
  }
end

# Create sample frames for benchmarking
frames = [
  HT2::DataFrame.new(1_u32, "Hello, World!".to_slice, HT2::FrameFlags::None),
  HT2::HeadersFrame.new(3_u32, Bytes.new(100), HT2::FrameFlags::END_HEADERS),
  HT2::WindowUpdateFrame.new(0_u32, 65_535_u32),
  HT2::PingFrame.new(Bytes.new(8)),
  HT2::SettingsFrame.new,
]

iterations = 10_000
pool = HT2::BufferPool.new(max_pool_size: 50, max_buffer_size: 16_384)

puts "Frame serialization benchmark (#{iterations} iterations per frame type)"
puts "=" * 60

# Warm up
frames.each(&.to_bytes)

# Benchmark without buffer pool
puts "\nWithout buffer pool:"
without_pool_time = Time.measure do
  iterations.times do
    frames.each(&.to_bytes)
  end
end
puts "  Time: #{without_pool_time.total_seconds.round(3)}s"

# Benchmark with buffer pool
puts "\nWith buffer pool:"
with_pool_time = Time.measure do
  iterations.times do
    frames.each do |frame|
      bytes = frame.to_bytes(pool)
      pool.release(bytes)
    end
  end
end
puts "  Time: #{with_pool_time.total_seconds.round(3)}s"

puts "\nPerformance improvement:"
speedup = without_pool_time.total_seconds / with_pool_time.total_seconds
puts "  Speedup: #{speedup.round(2)}x"
puts "  Time reduction: #{((1 - with_pool_time.total_seconds / without_pool_time.total_seconds) * 100).round(1)}%"

puts "\nBuffer pool stats:"
stats = pool.stats
puts "  Available buffers: #{stats[:available]}"
puts "  Max pool size: #{stats[:max_size]}"
