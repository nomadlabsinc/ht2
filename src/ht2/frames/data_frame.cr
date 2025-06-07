module HT2
  class DataFrame < Frame
    getter data : Bytes
    getter padding : UInt8

    def initialize(@stream_id : UInt32, @data : Bytes, @flags : FrameFlags = FrameFlags::None, @padding : UInt8 = 0)
      super(@stream_id, @flags)

      if @stream_id == 0
        raise ProtocolError.new("DATA frame cannot have stream ID 0")
      end

      if @padding > 0
        @flags = @flags | FrameFlags::PADDED
      end
    end

    def frame_type : FrameType
      FrameType::DATA
    end

    def payload : Bytes
      if @flags.padded?
        # Padded: Pad Length (1) + Data + Padding
        total_size = 1 + @data.size + @padding
        bytes = Bytes.new(total_size)
        bytes[0] = @padding
        @data.copy_to(bytes + 1, @data.size)
        # Padding bytes are already zero
        bytes
      else
        @data
      end
    end

    def self.parse_payload(stream_id : UInt32, flags : FrameFlags, payload : Bytes) : DataFrame
      if stream_id == 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "DATA frame with stream ID 0")
      end

      data_offset = 0
      padding = 0_u8

      if flags.padded?
        if payload.empty?
          raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "PADDED flag set but no padding length")
        end

        padding = payload[0]
        data_offset = 1

        if padding >= payload.size - 1
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Padding length >= frame payload size")
        end
      end

      data_length = payload.size - data_offset - padding
      data = payload[data_offset, data_length]

      DataFrame.new(stream_id, data, flags, padding)
    end
  end
end
