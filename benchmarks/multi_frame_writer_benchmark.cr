require "benchmark"
require "../src/ht2"

# Mock socket that counts writes
class CountingSocket < IO
  property write_count : Int32 = 0
  property total_bytes : Int64 = 0

  def read(slice : Bytes) : Int32
    0
  end

  def write(slice : Bytes) : Nil
    @write_count += 1
    @total_bytes += slice.size
  end
end

# Create test frames
def create_test_frames(count : Int32) : Array(HT2::Frame)
  frames = Array(HT2::Frame).new(count)

  count.times do |i|
    case i % 5
    when 0
      frames << HT2::DataFrame.new((i % 100 + 1).to_u32, "Test data #{i}".to_slice)
    when 1
      frames << HT2::WindowUpdateFrame.new(0_u32, 65_535_u32)
    when 2
      frames << HT2::PingFrame.new(Bytes.new(8, i.to_u8))
    when 3
      settings = HT2::SettingsFrame::Settings.new
      settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE] = 65_535_u32
      frames << HT2::SettingsFrame.new(settings: settings)
    else
      frames << HT2::RstStreamFrame.new((i % 100 + 1).to_u32, HT2::ErrorCode::NO_ERROR)
    end
  end

  frames
end

# Benchmark parameters
frame_counts = [10, 100, 1000]
iterations = 100
pool = HT2::BufferPool.new

puts "Multi-frame writer benchmark"
puts "=" * 60

frame_counts.each do |frame_count|
  frames = create_test_frames(frame_count)

  puts "\nBenchmarking with #{frame_count} frames (#{iterations} iterations):"
  puts "-" * 50

  # Individual frame sending
  total_writes_individual = 0
  individual_time = Time.measure do
    iterations.times do
      individual_socket = CountingSocket.new
      frames.each do |frame|
        individual_socket.write(frame.to_bytes(pool))
      end
      total_writes_individual += individual_socket.write_count
    end
  end

  avg_writes_individual = total_writes_individual.to_f / iterations
  puts "Individual frame sending:"
  puts "  Time: #{individual_time.total_seconds.round(3)}s"
  puts "  System calls per iteration: #{avg_writes_individual}"
  puts "  Avg writes per iteration: #{avg_writes_individual.round(1)}"

  # Multi-frame writer
  total_writes_multi = 0
  multi_time = Time.measure do
    iterations.times do
      multi_socket = CountingSocket.new
      writer = HT2::MultiFrameWriter.new(pool)
      writer.add_frames(frames)
      writer.flush_to(multi_socket)
      writer.release
      total_writes_multi += multi_socket.write_count
    end
  end

  avg_writes_multi = total_writes_multi.to_f / iterations
  puts "\nMulti-frame writer:"
  puts "  Time: #{multi_time.total_seconds.round(3)}s"
  puts "  Avg writes per iteration: #{avg_writes_multi.round(1)}"

  # Performance comparison
  puts "\nPerformance improvement:"
  speedup = individual_time.total_seconds / multi_time.total_seconds
  write_reduction = ((1 - avg_writes_multi / avg_writes_individual) * 100).round(1)

  puts "  Speedup: #{speedup.round(2)}x"
  puts "  System call reduction: #{write_reduction}%"
end

# Test DATA frame batching
puts "\n" + "=" * 60
puts "DATA frame batching benchmark"
puts "=" * 60

data_chunks = Array(Bytes).new
10.times do |i|
  data_chunks << ("Chunk #{i}: " + ("x" * 1000)).to_slice
end

iterations = 1000

# Individual DATA frames
individual_socket = CountingSocket.new
individual_time = Time.measure do
  iterations.times do
    data_chunks.each_with_index do |chunk, i|
      frame = HT2::DataFrame.new(
        1_u32,
        chunk,
        i == data_chunks.size - 1 ? HT2::FrameFlags::END_STREAM : HT2::FrameFlags::None
      )
      individual_socket.write(frame.to_bytes(pool))
    end
  end
end

puts "\nIndividual DATA frames:"
puts "  Time: #{individual_time.total_seconds.round(3)}s"
puts "  System calls: #{individual_socket.write_count}"

# Batched DATA frames
batch_socket = CountingSocket.new
batch_time = Time.measure do
  iterations.times do
    HT2::MultiFrameWriter.write_data_frames(batch_socket, 1_u32, data_chunks, end_stream: true)
  end
end

puts "\nBatched DATA frames:"
puts "  Time: #{batch_time.total_seconds.round(3)}s"
puts "  System calls: #{batch_socket.write_count}"

puts "\nImprovement:"
speedup = individual_time.total_seconds / batch_time.total_seconds
call_reduction = ((1 - batch_socket.write_count.to_f / individual_socket.write_count) * 100).round(1)

puts "  Speedup: #{speedup.round(2)}x"
puts "  System call reduction: #{call_reduction}%"
