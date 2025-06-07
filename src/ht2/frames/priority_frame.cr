module HT2
  class PriorityFrame < Frame
    getter priority : PriorityData

    def initialize(@stream_id : UInt32, @priority : PriorityData)
      super(@stream_id, FrameFlags::None)

      if @stream_id == 0
        raise ProtocolError.new("PRIORITY frame cannot have stream ID 0")
      end
    end

    def frame_type : FrameType
      FrameType::PRIORITY
    end

    def payload : Bytes
      bytes = Bytes.new(5)

      dep = @priority.stream_dependency
      bytes[0] = (dep >> 24).to_u8
      bytes[0] |= 0x80 if @priority.exclusive
      bytes[1] = (dep >> 16).to_u8
      bytes[2] = (dep >> 8).to_u8
      bytes[3] = dep.to_u8
      bytes[4] = @priority.weight

      bytes
    end

    def self.parse_payload(stream_id : UInt32, flags : FrameFlags, payload : Bytes) : PriorityFrame
      if stream_id == 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "PRIORITY frame with stream ID 0")
      end

      if payload.size != 5
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "PRIORITY payload must be 5 bytes")
      end

      exclusive = (payload[0] & 0x80) != 0
      dep = ((payload[0].to_u32 & 0x7F) << 24) |
            (payload[1].to_u32 << 16) |
            (payload[2].to_u32 << 8) |
            payload[3].to_u32
      weight = payload[4]

      priority = PriorityData.new(dep, weight, exclusive)

      PriorityFrame.new(stream_id, priority)
    end
  end
end
