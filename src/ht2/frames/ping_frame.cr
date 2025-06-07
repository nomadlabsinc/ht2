module HT2
  class PingFrame < Frame
    getter opaque_data : Bytes

    def initialize(@opaque_data : Bytes, @flags : FrameFlags = FrameFlags::None)
      super(0_u32, @flags) # PING always on stream 0

      if @opaque_data.size != 8
        raise ProtocolError.new("PING opaque data must be exactly 8 bytes")
      end
    end

    def frame_type : FrameType
      FrameType::PING
    end

    def payload : Bytes
      @opaque_data
    end

    def self.parse_payload(stream_id : UInt32, flags : FrameFlags, payload : Bytes) : PingFrame
      if stream_id != 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "PING frame with non-zero stream ID")
      end

      if payload.size != 8
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "PING payload must be 8 bytes")
      end

      PingFrame.new(payload, flags)
    end
  end
end
