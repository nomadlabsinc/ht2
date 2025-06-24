module HT2
  # Provides zero-copy frame forwarding capabilities by minimizing data copies
  # during frame serialization and transmission.
  module ZeroCopy
    # Writes frame header and payload without intermediate copying
    def self.write_frame(frame : Frame, io : IO) : Nil
      header_bytes = Bytes.new(Frame::HEADER_SIZE)
      write_frame_with_buffer(frame, io, header_bytes)
    end

    # Writes frame using provided header buffer to avoid allocation
    def self.write_frame_with_buffer(frame : Frame, io : IO, header_buffer : Bytes) : Nil
      raise ArgumentError.new("Header buffer too small") if header_buffer.size < Frame::HEADER_SIZE

      # Write header directly to buffer
      payload_bytes = frame.payload
      length = payload_bytes.size

      # Length (24 bits)
      header_buffer[0] = (length >> 16).to_u8
      header_buffer[1] = (length >> 8).to_u8
      header_buffer[2] = length.to_u8

      # Type (8 bits)
      header_buffer[3] = frame.type.value

      # Flags (8 bits)
      header_buffer[4] = frame.flags.value

      # Stream ID (32 bits)
      stream_id = frame.stream_id
      header_buffer[5] = (stream_id >> 24).to_u8
      header_buffer[6] = (stream_id >> 16).to_u8
      header_buffer[7] = (stream_id >> 8).to_u8
      header_buffer[8] = stream_id.to_u8

      # Write header and payload separately to avoid copying
      io.write(header_buffer[0, Frame::HEADER_SIZE])
      io.write(payload_bytes) unless payload_bytes.empty?
    end

    # Optimized DATA frame forwarding that avoids payload copying
    def self.forward_data_frame(data : Bytes, flags : FrameFlags, io : IO, stream_id : UInt32) : Nil
      header = Bytes.new(Frame::HEADER_SIZE)

      # Length (24 bits)
      length = data.size
      header[0] = ((length >> 16) & 0xFF).to_u8
      header[1] = ((length >> 8) & 0xFF).to_u8
      header[2] = (length & 0xFF).to_u8

      # Type (8 bits) - DATA frame
      header[3] = FrameType::DATA.value

      # Flags (8 bits)
      header[4] = flags.value

      # Stream ID (32 bits)
      header[5] = ((stream_id >> 24) & 0xFF).to_u8
      header[6] = ((stream_id >> 16) & 0xFF).to_u8
      header[7] = ((stream_id >> 8) & 0xFF).to_u8
      header[8] = (stream_id & 0xFF).to_u8

      # Write without copying data
      io.write(header)
      io.write(data) unless data.empty?
    end

    # BufferList manages multiple buffers without copying for stream data accumulation
    class BufferList
      @buffers : Array(Bytes)
      @total_size : Int32

      def initialize
        @buffers = Array(Bytes).new
        @total_size = 0
      end

      # Add buffer without copying
      def append(data : Bytes) : Nil
        return if data.empty?
        @buffers << data
        @total_size += data.size
      end

      # Get total size of all buffers
      def size : Int32
        @total_size
      end

      # Check if empty
      def empty? : Bool
        @buffers.empty?
      end

      # Clear all buffers
      def clear : Nil
        @buffers.clear
        @total_size = 0
      end

      # Read all buffers into destination
      def read_all(dest : Bytes) : Int32
        raise ArgumentError.new("Destination too small") if dest.size < @total_size

        offset = 0
        @buffers.each do |buffer|
          buffer.copy_to((dest + offset).to_unsafe, buffer.size)
          offset += buffer.size
        end

        @total_size
      end

      # Write all buffers to IO without copying
      def write_to(io : IO) : Int32
        written = 0
        @buffers.each do |buffer|
          io.write(buffer)
          written += buffer.size
        end
        written
      end

      # Create iterator for buffers
      def each(&) : Nil
        @buffers.each { |buffer| yield buffer }
      end
    end
  end
end
