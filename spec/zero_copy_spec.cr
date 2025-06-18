require "./spec_helper"

describe HT2::ZeroCopy do
  describe ".write_frame" do
    it "writes frame header and payload without intermediate copying" do
      io = IO::Memory.new
      frame = HT2::DataFrame.new(1_u32, "Hello World".to_slice)

      HT2::ZeroCopy.write_frame(frame, io)

      io.rewind
      bytes = io.to_slice

      # Verify header
      bytes.size.should eq(HT2::Frame::HEADER_SIZE + 11)

      # Length (24 bits)
      length = (bytes[0].to_u32 << 16) | (bytes[1].to_u32 << 8) | bytes[2].to_u32
      length.should eq(11)

      # Type
      bytes[3].should eq(HT2::FrameType::DATA.value)

      # Flags
      bytes[4].should eq(0)

      # Stream ID
      stream_id = ((bytes[5].to_u32 & 0x7F) << 24) | (bytes[6].to_u32 << 16) |
                  (bytes[7].to_u32 << 8) | bytes[8].to_u32
      stream_id.should eq(1)

      # Payload
      String.new(bytes[9, 11]).should eq("Hello World")
    end

    it "writes frame with provided header buffer" do
      io = IO::Memory.new
      frame = HT2::DataFrame.new(1_u32, "Test".to_slice)
      header_buffer = Bytes.new(HT2::Frame::HEADER_SIZE)

      HT2::ZeroCopy.write_frame_with_buffer(frame, io, header_buffer)

      io.rewind
      bytes = io.to_slice
      bytes.size.should eq(HT2::Frame::HEADER_SIZE + 4)
      String.new(bytes[9, 4]).should eq("Test")
    end

    it "raises error if header buffer is too small" do
      io = IO::Memory.new
      frame = HT2::DataFrame.new(1_u32, "Test".to_slice)
      small_buffer = Bytes.new(5)

      expect_raises(ArgumentError, "Header buffer too small") do
        HT2::ZeroCopy.write_frame_with_buffer(frame, io, small_buffer)
      end
    end
  end

  describe ".forward_data_frame" do
    it "forwards DATA frame without copying payload" do
      io = IO::Memory.new
      data = "Forward this data".to_slice
      flags = HT2::FrameFlags::END_STREAM
      stream_id = 3_u32

      HT2::ZeroCopy.forward_data_frame(data, flags, io, stream_id)

      io.rewind
      bytes = io.to_slice

      # Verify header
      bytes.size.should eq(HT2::Frame::HEADER_SIZE + 17)

      # Length
      length = (bytes[0].to_u32 << 16) | (bytes[1].to_u32 << 8) | bytes[2].to_u32
      length.should eq(17)

      # Type
      bytes[3].should eq(HT2::FrameType::DATA.value)

      # Flags
      bytes[4].should eq(flags.value)

      # Stream ID
      parsed_stream_id = ((bytes[5].to_u32 & 0x7F) << 24) | (bytes[6].to_u32 << 16) |
                         (bytes[7].to_u32 << 8) | bytes[8].to_u32
      parsed_stream_id.should eq(stream_id)

      # Payload
      String.new(bytes[9, 17]).should eq("Forward this data")
    end

    it "handles empty data correctly" do
      io = IO::Memory.new
      data = Bytes.empty
      flags = HT2::FrameFlags::None
      stream_id = 5_u32

      HT2::ZeroCopy.forward_data_frame(data, flags, io, stream_id)

      io.rewind
      bytes = io.to_slice
      bytes.size.should eq(HT2::Frame::HEADER_SIZE)

      # Length should be 0
      length = (bytes[0].to_u32 << 16) | (bytes[1].to_u32 << 8) | bytes[2].to_u32
      length.should eq(0)
    end
  end

  describe "BufferList" do
    describe "#append" do
      it "appends buffers without copying" do
        list = HT2::ZeroCopy::BufferList.new
        buffer1 = "First".to_slice
        buffer2 = "Second".to_slice

        list.append(buffer1)
        list.append(buffer2)

        list.size.should eq(11)
        list.empty?.should be_false
      end

      it "ignores empty buffers" do
        list = HT2::ZeroCopy::BufferList.new
        list.append(Bytes.empty)

        list.size.should eq(0)
        list.empty?.should be_true
      end
    end

    describe "#read_all" do
      it "reads all buffers into destination" do
        list = HT2::ZeroCopy::BufferList.new
        list.append("Hello ".to_slice)
        list.append("World".to_slice)

        dest = Bytes.new(11)
        bytes_read = list.read_all(dest)

        bytes_read.should eq(11)
        String.new(dest).should eq("Hello World")
      end

      it "raises error if destination is too small" do
        list = HT2::ZeroCopy::BufferList.new
        list.append("Too large".to_slice)

        small_dest = Bytes.new(5)
        expect_raises(ArgumentError, "Destination too small") do
          list.read_all(small_dest)
        end
      end
    end

    describe "#write_to" do
      it "writes all buffers to IO without copying" do
        list = HT2::ZeroCopy::BufferList.new
        list.append("Part1 ".to_slice)
        list.append("Part2 ".to_slice)
        list.append("Part3".to_slice)

        io = IO::Memory.new
        bytes_written = list.write_to(io)

        bytes_written.should eq(17)
        io.to_s.should eq("Part1 Part2 Part3")
      end
    end

    describe "#clear" do
      it "clears all buffers" do
        list = HT2::ZeroCopy::BufferList.new
        list.append("Data".to_slice)

        list.clear

        list.size.should eq(0)
        list.empty?.should be_true
      end
    end

    describe "#each" do
      it "iterates over buffers" do
        list = HT2::ZeroCopy::BufferList.new
        list.append("A".to_slice)
        list.append("B".to_slice)
        list.append("C".to_slice)

        result = [] of String
        list.each { |buffer| result << String.new(buffer) }

        result.should eq(["A", "B", "C"])
      end
    end
  end

  describe "DataFrame zero-copy write" do
    it "uses zero-copy for non-padded frames" do
      io = IO::Memory.new
      frame = HT2::DataFrame.new(1_u32, "Zero-copy data".to_slice)

      frame.write_to(io)

      io.rewind
      bytes = io.to_slice

      # Verify it wrote correctly
      bytes.size.should eq(HT2::Frame::HEADER_SIZE + 14)
      String.new(bytes[9, 14]).should eq("Zero-copy data")
    end

    it "uses regular serialization for padded frames" do
      io = IO::Memory.new
      frame = HT2::DataFrame.new(1_u32, "Padded".to_slice, HT2::FrameFlags::PADDED, 5_u8)

      frame.write_to(io)

      io.rewind
      bytes = io.to_slice

      # Padded frame: 9 (header) + 1 (pad length) + 6 (data) + 5 (padding)
      bytes.size.should eq(21)

      # Check padding length byte
      bytes[9].should eq(5)

      # Check data
      String.new(bytes[10, 6]).should eq("Padded")

      # Check padding (should be zeros)
      bytes[16, 5].all? { |b| b == 0 }.should be_true
    end
  end
end
