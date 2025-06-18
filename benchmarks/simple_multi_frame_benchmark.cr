require "../src/ht2"

# Create test DATA frames
data_chunks = Array(Bytes).new
10.times do |i|
  data_chunks << "Test data chunk #{i} with some content to make it realistic".to_slice
end

puts "DATA Frame Batching Benchmark"
puts "=" * 60

io = IO::Memory.new
iterations = 1000

# Individual DATA frame writes
io.clear
individual_time = Time.measure do
  iterations.times do
    data_chunks.each_with_index do |chunk, i|
      frame = HT2::DataFrame.new(
        1_u32,
        chunk,
        i == data_chunks.size - 1 ? HT2::FrameFlags::END_STREAM : HT2::FrameFlags::None
      )
      # This will use zero-copy write
      frame.write_to(io)
    end
  end
end

individual_bytes = io.size
puts "\nIndividual DATA frames (with zero-copy):"
puts "  Time: #{individual_time.total_seconds.round(3)}s"
puts "  Bytes written: #{individual_bytes}"
puts "  Throughput: #{(individual_bytes / individual_time.total_seconds / 1024 / 1024).round(2)} MB/s"

# Reset IO
io.clear

# Batched DATA frame writes
batch_time = Time.measure do
  iterations.times do
    HT2::MultiFrameWriter.write_data_frames(io, 1_u32, data_chunks, end_stream: true)
  end
end

batch_bytes = io.size
puts "\nBatched DATA frames:"
puts "  Time: #{batch_time.total_seconds.round(3)}s"
puts "  Bytes written: #{batch_bytes}"
puts "  Throughput: #{(batch_bytes / batch_time.total_seconds / 1024 / 1024).round(2)} MB/s"

puts "\nImprovement:"
speedup = individual_time.total_seconds / batch_time.total_seconds
puts "  Speedup: #{speedup.round(2)}x"
puts "  Throughput increase: #{((speedup - 1) * 100).round(1)}%"

# Test mixed frame batching
puts "\n" + "=" * 60
puts "Mixed Frame Batching"
puts "=" * 60

pool = HT2::BufferPool.new

# Create mixed frames
mixed_frames = [
  HT2::WindowUpdateFrame.new(0_u32, 65535_u32),
  HT2::SettingsFrame.new,
  HT2::PingFrame.new(Bytes.new(8, 1)),
  HT2::DataFrame.new(1_u32, "Some data".to_slice),
  HT2::WindowUpdateFrame.new(1_u32, 32768_u32),
]

io.clear

# Individual writes
individual_mixed_time = Time.measure do
  iterations.times do
    mixed_frames.each do |frame|
      frame_bytes = frame.to_bytes(pool)
      io.write(frame_bytes)
      pool.release(frame_bytes)
    end
  end
end

puts "\nIndividual mixed frame writes:"
puts "  Time: #{individual_mixed_time.total_seconds.round(3)}s"

io.clear

# Batched writes
writer = HT2::MultiFrameWriter.new(pool)
batch_mixed_time = Time.measure do
  iterations.times do
    writer.add_frames(mixed_frames)
    writer.flush_to(io)
  end
end
writer.release

puts "\nBatched mixed frame writes:"
puts "  Time: #{batch_mixed_time.total_seconds.round(3)}s"

speedup = individual_mixed_time.total_seconds / batch_mixed_time.total_seconds
puts "\nSpeedup: #{speedup.round(2)}x"
