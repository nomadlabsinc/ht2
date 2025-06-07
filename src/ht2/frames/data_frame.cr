require "../security"

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

        # Limit padding to prevent oracle attacks
        if @padding > Security::MAX_PADDING_LENGTH
          raise ProtocolError.new("Padding length #{@padding} exceeds maximum #{Security::MAX_PADDING_LENGTH}")
        end
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
        @data.copy_to((bytes + 1).to_unsafe, @data.size)
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
          # Use consistent error to prevent oracle attacks
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid frame format")
        end

        padding = payload[0]
        data_offset = 1

        if padding >= payload.size - 1
          # Use consistent error to prevent oracle attacks
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid frame format")
        end

        # Limit padding to prevent oracle attacks
        if padding > Security::MAX_PADDING_LENGTH
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid frame format")
        end
      end

      data_length = payload.size - data_offset - padding
      data = payload[data_offset, data_length]

      DataFrame.new(stream_id, data, flags, padding)
    end
  end
end
