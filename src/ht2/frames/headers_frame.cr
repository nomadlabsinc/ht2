module HT2
  class HeadersFrame < Frame
    getter header_block : Bytes
    getter padding : UInt8
    getter priority : PriorityData?

    def initialize(@stream_id : UInt32, @header_block : Bytes, @flags : FrameFlags = FrameFlags::None,
                   @padding : UInt8 = 0, @priority : PriorityData? = nil)
      super(@stream_id, @flags)

      if @stream_id == 0
        raise ProtocolError.new("HEADERS frame cannot have stream ID 0")
      end

      if @padding > 0
        @flags = @flags | FrameFlags::PADDED
      end

      if @priority
        @flags = @flags | FrameFlags::PRIORITY
      end
    end

    def frame_type : FrameType
      FrameType::HEADERS
    end

    def payload : Bytes
      offset = 0
      priority_size = @priority ? 5 : 0
      padding_size = @flags.padded? ? 1 : 0

      total_size = padding_size + priority_size + @header_block.size + @padding
      bytes = Bytes.new(total_size)

      # Pad length
      if @flags.padded?
        bytes[offset] = @padding
        offset += 1
      end

      # Priority data
      if priority = @priority
        dep = priority.stream_dependency
        bytes[offset] = (dep >> 24).to_u8
        bytes[offset] |= 0x80 if priority.exclusive
        bytes[offset + 1] = (dep >> 16).to_u8
        bytes[offset + 2] = (dep >> 8).to_u8
        bytes[offset + 3] = dep.to_u8
        bytes[offset + 4] = priority.weight
        offset += 5
      end

      # Header block
      @header_block.copy_to(bytes + offset, @header_block.size)

      bytes
    end

    def self.parse_payload(stream_id : UInt32, flags : FrameFlags, payload : Bytes) : HeadersFrame
      if stream_id == 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "HEADERS frame with stream ID 0")
      end

      offset = 0
      padding = 0_u8
      priority = nil

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

      # Parse priority
      if flags.priority?
        if payload.size - offset < 5
          raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "PRIORITY flag set but insufficient data")
        end

        exclusive = (payload[offset] & 0x80) != 0
        dep = ((payload[offset].to_u32 & 0x7F) << 24) |
              (payload[offset + 1].to_u32 << 16) |
              (payload[offset + 2].to_u32 << 8) |
              payload[offset + 3].to_u32
        weight = payload[offset + 4]

        priority = PriorityData.new(dep, weight, exclusive)
        offset += 5
      end

      # Extract header block
      header_block_size = payload.size - offset - padding
      header_block = payload[offset, header_block_size]

      HeadersFrame.new(stream_id, header_block, flags, padding, priority)
    end
  end

  struct PriorityData
    getter stream_dependency : UInt32
    getter weight : UInt8
    getter exclusive : Bool

    def initialize(@stream_dependency : UInt32, @weight : UInt8, @exclusive : Bool = false)
    end
  end
end
