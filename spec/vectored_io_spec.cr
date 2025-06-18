require "./spec_helper"
require "../src/ht2/vectored_io"

describe HT2::VectoredIO do
  describe ".writev" do
    it "writes multiple slices in a single system call" do
      # Create a pipe for testing
      reader, writer = IO.pipe

      slices = [
        "Hello, ".to_slice,
        "vectored ".to_slice,
        "I/O!".to_slice,
      ]

      # Write using vectored I/O
      bytes_written = HT2::VectoredIO.writev(writer, slices)
      writer.close

      # Read and verify
      result = reader.gets_to_end
      result.should eq("Hello, vectored I/O!")
      bytes_written.should eq(20) # "Hello, vectored I/O!" is 20 characters
    end

    it "handles empty slice array" do
      reader, writer = IO.pipe
      bytes_written = HT2::VectoredIO.writev(writer, [] of Bytes)
      bytes_written.should eq(0)
      writer.close
      reader.close
    end

    it "handles large number of slices" do
      reader, writer = IO.pipe

      # Create many small slices
      slices = (1..100).map { |i| "#{i}\n".to_slice }

      bytes_written = HT2::VectoredIO.writev(writer, slices)
      writer.close

      result = reader.gets_to_end
      expected = (1..100).map { |i| "#{i}\n" }.join
      result.should eq(expected)
      bytes_written.should eq(expected.bytesize)
    end

    it "handles slices exceeding MAX_IOV_COUNT" do
      reader, writer = IO.pipe

      # Create more slices than MAX_IOV_COUNT
      slice_count = HT2::VectoredIO::MAX_IOV_COUNT + 100
      slices = (1..slice_count).map { |i| "x".to_slice }

      bytes_written = HT2::VectoredIO.writev(writer, slices)
      writer.close

      result = reader.gets_to_end
      result.size.should eq(slice_count)
      bytes_written.should eq(slice_count)
    end
  end

  describe ".write_frames" do
    it "writes multiple frames using vectored I/O" do
      reader, writer = IO.pipe
      buffer_pool = HT2::BufferPool.new

      frames = [
        HT2::PingFrame.new("PING1234".to_slice),
        HT2::WindowUpdateFrame.new(0, 65535),
        HT2::PingFrame.new("PING5678".to_slice, HT2::FrameFlags::ACK),
      ]

      bytes_written = HT2::VectoredIO.write_frames(writer, frames, buffer_pool)
      writer.close

      # Read frames back
      data = reader.gets_to_end.to_slice
      offset = 0

      # Parse first frame
      frame1_size = HT2::Frame::HEADER_SIZE + 8 # PING payload is 8 bytes
      frame1 = HT2::Frame.parse(data[offset, frame1_size])
      frame1.should be_a(HT2::PingFrame)
      frame1.as(HT2::PingFrame).opaque_data.should eq("PING1234".to_slice)
      offset += frame1_size

      # Parse second frame
      frame2_size = HT2::Frame::HEADER_SIZE + 4 # WINDOW_UPDATE payload is 4 bytes
      frame2 = HT2::Frame.parse(data[offset, frame2_size])
      frame2.should be_a(HT2::WindowUpdateFrame)
      frame2.as(HT2::WindowUpdateFrame).window_size_increment.should eq(65535)
      offset += frame2_size

      # Parse third frame
      frame3_size = HT2::Frame::HEADER_SIZE + 8 # PING payload is 8 bytes
      frame3 = HT2::Frame.parse(data[offset, frame3_size])
      frame3.should be_a(HT2::PingFrame)
      frame3.as(HT2::PingFrame).opaque_data.should eq("PING5678".to_slice)
      frame3.as(HT2::PingFrame).flags.ack?.should be_true

      # Verify total bytes written
      expected_size = 3 * HT2::Frame::HEADER_SIZE + 8 + 4 + 8 # 3 headers + payloads
      bytes_written.should eq(expected_size)
    end
  end

  describe ".write_data_frames" do
    it "writes DATA frames with zero-copy optimization" do
      reader, writer = IO.pipe

      data1 = "Hello, World!".to_slice
      data2 = "This is vectored I/O".to_slice

      frames = [
        HT2::DataFrame.new(1, data1, HT2::FrameFlags::None),
        HT2::DataFrame.new(1, data2, HT2::FrameFlags::END_STREAM),
      ]

      bytes_written = HT2::VectoredIO.write_data_frames(writer, frames)
      writer.close

      # Read frames back
      all_data = reader.gets_to_end.to_slice
      offset = 0

      # Parse first DATA frame
      frame1_size = HT2::Frame::HEADER_SIZE + data1.size
      frame1 = HT2::Frame.parse(all_data[offset, frame1_size])
      frame1.should be_a(HT2::DataFrame)
      frame1.as(HT2::DataFrame).data.should eq(data1)
      frame1.as(HT2::DataFrame).stream_id.should eq(1)
      offset += frame1_size

      # Parse second DATA frame
      frame2_size = HT2::Frame::HEADER_SIZE + data2.size
      frame2 = HT2::Frame.parse(all_data[offset, frame2_size])
      frame2.should be_a(HT2::DataFrame)
      frame2.as(HT2::DataFrame).data.should eq(data2)
      frame2.as(HT2::DataFrame).flags.end_stream?.should be_true

      # Verify total bytes written
      expected_size = 2 * HT2::Frame::HEADER_SIZE + data1.size + data2.size
      bytes_written.should eq(expected_size)
    end

    it "handles DATA frames with padding" do
      reader, writer = IO.pipe

      data = "Padded data".to_slice
      frame = HT2::DataFrame.new(3, data, HT2::FrameFlags::PADDED, 10)

      bytes_written = HT2::VectoredIO.write_data_frames(writer, [frame])
      writer.close

      # Read frame back
      all_data = reader.gets_to_end.to_slice
      frame_size = HT2::Frame::HEADER_SIZE + 1 + data.size + 10 # header + pad_length + data + padding
      parsed = HT2::Frame.parse(all_data[0, frame_size])
      parsed.should be_a(HT2::DataFrame)
      df = parsed.as(HT2::DataFrame)
      df.data.should eq(data)
      df.padding.should eq(10)
      df.flags.padded?.should be_true

      # Verify total bytes written (header + pad_length + data + padding)
      expected_size = HT2::Frame::HEADER_SIZE + 1 + data.size + 10
      bytes_written.should eq(expected_size)
    end
  end
end
