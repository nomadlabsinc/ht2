require "./spec_helper"

describe HT2::MultiFrameWriter do
  it "initializes with buffer pool" do
    pool = HT2::BufferPool.new
    writer = HT2::MultiFrameWriter.new(pool)

    writer.buffer_pool.should eq(pool)
    writer.buffered_bytes.should eq(0)
    writer.buffered_frames.should eq(0)
  end

  it "buffers small frames efficiently" do
    pool = HT2::BufferPool.new
    writer = HT2::MultiFrameWriter.new(pool, buffer_size: 1024)

    # Add small frames
    ping_frame = HT2::PingFrame.new(Bytes.new(8, 0))
    settings_frame = HT2::SettingsFrame.new

    writer.add_frame(ping_frame)
    writer.add_frame(settings_frame)

    writer.buffered_frames.should eq(2)
    writer.buffered_bytes.should be > 0
  end

  it "handles DATA frames with zero-copy optimization" do
    pool = HT2::BufferPool.new
    writer = HT2::MultiFrameWriter.new(pool)

    # Non-padded DATA frames should be queued separately
    data_frame = HT2::DataFrame.new(1_u32, "Hello World".to_slice)
    writer.add_frame(data_frame)

    # DATA frames are counted but not buffered in main buffer
    writer.buffered_frames.should eq(1)
  end

  it "flushes frames to IO correctly" do
    pool = HT2::BufferPool.new
    writer = HT2::MultiFrameWriter.new(pool)
    io = IO::Memory.new

    # Add various frame types
    ping_frame = HT2::PingFrame.new(Bytes.new(8, 1))
    settings_frame = HT2::SettingsFrame.new
    data_frame = HT2::DataFrame.new(1_u32, "Test data".to_slice)

    writer.add_frame(ping_frame)
    writer.add_frame(settings_frame)
    writer.add_frame(data_frame)

    writer.flush_to(io)

    # Verify data was written
    io.size.should be > 0
    writer.buffered_frames.should eq(0)
    writer.buffered_bytes.should eq(0)
  end

  it "handles multiple frames in batch" do
    pool = HT2::BufferPool.new
    writer = HT2::MultiFrameWriter.new(pool)

    frames = [
      HT2::WindowUpdateFrame.new(0_u32, 65535_u32),
      HT2::PingFrame.new(Bytes.new(8, 2)),
      HT2::SettingsFrame.new(HT2::FrameFlags::ACK),
    ]

    writer.add_frames(frames)
    writer.buffered_frames.should eq(3)
  end

  it "respects frame priorities" do
    pool = HT2::BufferPool.new
    writer = HT2::MultiFrameWriter.new(pool)
    io = IO::Memory.new

    # Create prioritized frames (higher priority = sent first)
    frames = [
      HT2::MultiFrameWriter::PrioritizedFrame.new(
        HT2::PingFrame.new(Bytes.new(8, 1)),
        priority: 1
      ),
      HT2::MultiFrameWriter::PrioritizedFrame.new(
        HT2::WindowUpdateFrame.new(0_u32, 1000_u32),
        priority: 10
      ),
      HT2::MultiFrameWriter::PrioritizedFrame.new(
        HT2::SettingsFrame.new,
        priority: 5
      ),
    ]

    writer.add_prioritized_frames(frames)
    writer.buffered_frames.should eq(3)

    writer.flush_to(io)

    # Parse written frames to verify order
    io.rewind

    # First should be WINDOW_UPDATE (priority 10)
    _, type1, _, _ = HT2::Frame.parse_header(Bytes.new(9).tap { |b| io.read_fully(b) })
    type1.should eq(HT2::FrameType::WINDOW_UPDATE)

    # Skip payload
    io.skip(4)

    # Second should be SETTINGS (priority 5)
    _, type2, _, _ = HT2::Frame.parse_header(Bytes.new(9).tap { |b| io.read_fully(b) })
    type2.should eq(HT2::FrameType::SETTINGS)
  end

  it "handles large frames that exceed buffer size" do
    pool = HT2::BufferPool.new
    writer = HT2::MultiFrameWriter.new(pool, buffer_size: 100) # Small buffer

    # This frame will be larger than buffer when serialized
    large_headers = Bytes.new(200, 0)
    headers_frame = HT2::HeadersFrame.new(1_u32, large_headers)

    # Should not raise - frame is queued despite being larger than buffer
    writer.add_frame(headers_frame)

    # Frame is queued and will be written when flushed
    writer.buffered_frames.should eq(1)

    # Verify it can be flushed successfully
    io = IO::Memory.new
    writer.flush_to(io)
    writer.buffered_frames.should eq(0)
    io.size.should be > 200 # Frame was written
  end

  it "releases resources back to pool" do
    pool = HT2::BufferPool.new
    writer = HT2::MultiFrameWriter.new(pool)

    initial_stats = pool.stats

    writer.add_frame(HT2::PingFrame.new(Bytes.new(8)))
    writer.release

    # Buffer should be released back to pool
    writer.write_buffer.size.should eq(0)
  end

  describe ".write_data_frames" do
    it "writes multiple DATA frames efficiently" do
      io = IO::Memory.new
      stream_id = 1_u32
      chunks = [
        "First chunk".to_slice,
        "Second chunk".to_slice,
        "Final chunk".to_slice,
      ]

      HT2::MultiFrameWriter.write_data_frames(io, stream_id, chunks, end_stream: true)

      io.rewind

      # Verify frames were written
      chunks.each_with_index do |chunk, i|
        length, type, flags, sid = HT2::Frame.parse_header(Bytes.new(9).tap { |b| io.read_fully(b) })

        type.should eq(HT2::FrameType::DATA)
        sid.should eq(stream_id)
        length.should eq(chunk.size)

        # Last frame should have END_STREAM
        if i == chunks.size - 1
          flags.end_stream?.should be_true
        else
          flags.end_stream?.should be_false
        end

        # Skip payload
        io.skip(length)
      end
    end

    it "handles empty chunks array" do
      io = IO::Memory.new
      HT2::MultiFrameWriter.write_data_frames(io, 1_u32, [] of Bytes)
      io.size.should eq(0)
    end
  end

  describe ".write_headers_with_continuations" do
    it "writes single HEADERS frame when data fits" do
      io = IO::Memory.new
      stream_id = 3_u32
      header_block = Bytes.new(100, 42)

      HT2::MultiFrameWriter.write_headers_with_continuations(
        io, stream_id, header_block, end_stream: true
      )

      io.rewind

      # Should be single HEADERS frame
      length, type, flags, sid = HT2::Frame.parse_header(Bytes.new(9).tap { |b| io.read_fully(b) })

      type.should eq(HT2::FrameType::HEADERS)
      sid.should eq(stream_id)
      flags.end_headers?.should be_true
      flags.end_stream?.should be_true
      length.should eq(header_block.size)
    end

    it "splits large headers into HEADERS + CONTINUATION frames" do
      io = IO::Memory.new
      stream_id = 5_u32
      max_frame_size = 100_u32

      # Create header block larger than max frame size
      header_block = Bytes.new(250, 33)

      HT2::MultiFrameWriter.write_headers_with_continuations(
        io, stream_id, header_block,
        end_stream: false,
        max_frame_size: max_frame_size
      )

      io.rewind

      # First frame should be HEADERS without END_HEADERS
      length1, type1, flags1, sid1 = HT2::Frame.parse_header(Bytes.new(9).tap { |b| io.read_fully(b) })
      type1.should eq(HT2::FrameType::HEADERS)
      sid1.should eq(stream_id)
      flags1.end_headers?.should be_false
      length1.should eq(max_frame_size)
      io.skip(length1)

      # Second frame should be CONTINUATION without END_HEADERS
      length2, type2, flags2, sid2 = HT2::Frame.parse_header(Bytes.new(9).tap { |b| io.read_fully(b) })
      type2.should eq(HT2::FrameType::CONTINUATION)
      sid2.should eq(stream_id)
      flags2.end_headers?.should be_false
      length2.should eq(max_frame_size)
      io.skip(length2)

      # Third frame should be CONTINUATION with END_HEADERS
      length3, type3, flags3, sid3 = HT2::Frame.parse_header(Bytes.new(9).tap { |b| io.read_fully(b) })
      type3.should eq(HT2::FrameType::CONTINUATION)
      sid3.should eq(stream_id)
      flags3.end_headers?.should be_true
      length3.should eq(50) # Remaining bytes
    end

    it "includes priority data in HEADERS frame" do
      io = IO::Memory.new
      stream_id = 7_u32
      header_block = Bytes.new(50, 99)
      priority = HT2::PriorityData.new(3_u32, 255_u8, exclusive: true)

      HT2::MultiFrameWriter.write_headers_with_continuations(
        io, stream_id, header_block,
        priority: priority
      )

      io.rewind

      # Parse and verify HEADERS frame
      full_frame = Bytes.new(9 + 5 + 50) # header + priority + block
      io.read_fully(full_frame)

      frame = HT2::Frame.parse(full_frame).as(HT2::HeadersFrame)
      frame.priority.should_not be_nil
      frame.priority.not_nil!.stream_dependency.should eq(3_u32)
      frame.priority.not_nil!.weight.should eq(255_u8)
      frame.priority.not_nil!.exclusive?.should be_true
    end
  end

  describe ".for_connection" do
    it "creates writer using connection's buffer pool" do
      socket = IO::Memory.new
      connection = HT2::Connection.new(socket, is_server: false)

      writer = HT2::MultiFrameWriter.for_connection(connection)
      writer.buffer_pool.should eq(connection.buffer_pool)
    end
  end

  it "handles concurrent access safely" do
    pool = HT2::BufferPool.new
    writer = HT2::MultiFrameWriter.new(pool)
    io = IO::Memory.new

    done = Channel(Nil).new

    # Multiple fibers adding frames concurrently
    10.times do |i|
      spawn do
        writer.add_frame(HT2::PingFrame.new(Bytes.new(8, i.to_u8)))
        done.send(nil)
      end
    end

    # Wait for all fibers
    10.times { done.receive }

    writer.buffered_frames.should eq(10)

    # Flush should work correctly
    writer.flush_to(io)
    writer.buffered_frames.should eq(0)
  end
end
