module HT2
  class PushPromiseFrame < Frame
    getter promised_stream_id : UInt32
    getter header_block : Bytes
    getter padding : UInt8

    def initialize(@stream_id : UInt32, @promised_stream_id : UInt32, @header_block : Bytes,
                   @flags : FrameFlags = FrameFlags::None, @padding : UInt8 = 0)
      super(@stream_id, @flags)

      if @stream_id == 0
        raise ProtocolError.new("PUSH_PROMISE frame cannot have stream ID 0")
      end

      if @padding > 0
        @flags = @flags | FrameFlags::PADDED
      end
    end

    def frame_type : FrameType
      FrameType::PUSH_PROMISE
    end

    def payload : Bytes
      offset = 0
      padding_size = @flags.padded? ? 1 : 0

      total_size = padding_size + 4 + @header_block.size + @padding
      bytes = Bytes.new(total_size)

      # Pad length
      if @flags.padded?
        bytes[offset] = @padding
        offset += 1
      end

      # Promised Stream ID (31 bits with reserved bit)
      bytes[offset] = (@promised_stream_id >> 24).to_u8 & 0x7F # Clear reserved bit
      bytes[offset + 1] = (@promised_stream_id >> 16).to_u8
      bytes[offset + 2] = (@promised_stream_id >> 8).to_u8
      bytes[offset + 3] = @promised_stream_id.to_u8
      offset += 4

      # Header block
      @header_block.copy_to((bytes + offset).to_unsafe, @header_block.size)

      bytes
    end

    def self.parse_payload(stream_id : UInt32, flags : FrameFlags, payload : Bytes) : PushPromiseFrame
      if stream_id == 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "PUSH_PROMISE frame with stream ID 0")
      end

      offset = 0
      padding = 0_u8

      # Parse padding
      if flags.padded?
        if payload.empty?
          raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "PADDED flag set but no padding length")
        end

        padding = payload[0]
        offset += 1

        if padding >= payload.size - offset
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Padding length >= remaining frame size")
        end
      end

      if payload.size - offset < 4
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "PUSH_PROMISE payload too small")
      end

      # Promised Stream ID (ignore reserved bit)
      promised_stream_id = ((payload[offset].to_u32 & 0x7F) << 24) |
                           (payload[offset + 1].to_u32 << 16) |
                           (payload[offset + 2].to_u32 << 8) |
                           payload[offset + 3].to_u32
      offset += 4

      # Extract header block
      header_block_size = payload.size - offset - padding
      header_block = payload[offset, header_block_size]

      PushPromiseFrame.new(stream_id, promised_stream_id, header_block, flags, padding)
    end
  end
end
