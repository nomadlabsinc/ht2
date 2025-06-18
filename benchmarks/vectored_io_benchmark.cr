require "benchmark"
require "../src/ht2"

# Benchmark comparing sequential writes vs vectored I/O for multi-frame operations

def create_test_frames(count : Int32) : Array(HT2::Frame)
  frames = [] of HT2::Frame

  count.times do |i|
    case i % 4
    when 0
      # Small control frame
      frames << HT2::PingFrame.new("PING#{i}".ljust(8, '0').to_slice)
    when 1
      # Window update
      frames << HT2::WindowUpdateFrame.new(0, 65535)
    when 2
      # Settings frame
      settings = HT2::SettingsFrame::Settings.new
      settings[HT2::SettingsFrame::Identifier::INITIAL_WINDOW_SIZE] = 131072_u32
      frames << HT2::SettingsFrame.new(settings)
    else
      # Data frame
      data = "Data frame #{i} with some payload content".to_slice
      frames << HT2::DataFrame.new((i % 100).to_u32 + 1, data, HT2::FrameFlags::None)
    end
  end

  frames
end

def benchmark_sequential_writes(frames : Array(HT2::Frame), iterations : Int32) : Time::Span
  buffer_pool = HT2::BufferPool.new

  Benchmark.measure do
    iterations.times do
      io = IO::Memory.new
      frames.each do |frame|
        io.write(frame.to_bytes(buffer_pool))
      end
    end
  end
end

def benchmark_vectored_writes(frames : Array(HT2::Frame), iterations : Int32) : Time::Span
  buffer_pool = HT2::BufferPool.new

  Benchmark.measure do
    iterations.times do
      reader, writer = IO.pipe
      begin
        HT2::VectoredIO.write_frames(writer, frames, buffer_pool)
      ensure
        writer.close
        reader.close
      end
    end
  end
end

def benchmark_multi_frame_writer(frames : Array(HT2::Frame), iterations : Int32) : Time::Span
  buffer_pool = HT2::BufferPool.new

  Benchmark.measure do
    iterations.times do
      io = IO::Memory.new
      writer = HT2::MultiFrameWriter.new(buffer_pool)
      writer.add_frames(frames)
      writer.flush_to(io)
      writer.release
    end
  end
end

# Run benchmarks
puts "Vectored I/O Performance Benchmark"
puts "================================="
puts

frame_counts = [10, 50, 100, 500]
iterations = 1000

frame_counts.each do |count|
  frames = create_test_frames(count)
  total_bytes = frames.sum { |f| HT2::Frame::HEADER_SIZE + f.payload.size }

  puts "Testing with #{count} frames (#{total_bytes} bytes total):"

  sequential_time = benchmark_sequential_writes(frames, iterations)
  vectored_time = benchmark_vectored_writes(frames, iterations)
  multi_frame_time = benchmark_multi_frame_writer(frames, iterations)

  puts "  Sequential writes:    #{sequential_time.total_milliseconds.round(2)}ms"
  puts "  Vectored I/O:        #{vectored_time.total_milliseconds.round(2)}ms"
  puts "  MultiFrameWriter:    #{multi_frame_time.total_milliseconds.round(2)}ms"

  if vectored_time < sequential_time
    speedup = (sequential_time.total_milliseconds / vectored_time.total_milliseconds).round(2)
    puts "  Vectored I/O speedup: #{speedup}x faster"
  end

  puts
end

# Benchmark DATA frame specific operations
puts "DATA Frame Vectored I/O Benchmark"
puts "================================"
puts

data_sizes = [1024, 4096, 16384, 65536]
frame_count = 20

data_sizes.each do |size|
  data_frames = (0...frame_count).map do |i|
    data = Bytes.new(size) { |j| (j % 256).to_u8 }
    HT2::DataFrame.new((i % 10).to_u32 + 1, data, HT2::FrameFlags::None)
  end

  puts "Testing #{frame_count} DATA frames of #{size} bytes each:"

  sequential_data_time = Benchmark.measure do
    iterations.times do
      io = IO::Memory.new
      data_frames.each { |frame| frame.write_to(io) }
    end
  end

  vectored_data_time = Benchmark.measure do
    iterations.times do
      reader, writer = IO.pipe
      begin
        HT2::VectoredIO.write_data_frames(writer, data_frames)
      ensure
        writer.close
        reader.close
      end
    end
  end

  puts "  Sequential:  #{sequential_data_time.total_milliseconds.round(2)}ms"
  puts "  Vectored:    #{vectored_data_time.total_milliseconds.round(2)}ms"

  if vectored_data_time < sequential_data_time
    speedup = (sequential_data_time.total_milliseconds / vectored_data_time.total_milliseconds).round(2)
    puts "  Speedup:     #{speedup}x faster"
  end

  puts
end
