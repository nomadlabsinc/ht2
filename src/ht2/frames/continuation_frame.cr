module HT2
  class ContinuationFrame < Frame
    getter header_block : Bytes

    def initialize(@stream_id : UInt32, @header_block : Bytes, @flags : FrameFlags = FrameFlags::None)
      super(@stream_id, @flags)

      if @stream_id == 0
        raise ProtocolError.new("CONTINUATION frame cannot have stream ID 0")
      end
    end

    def frame_type : FrameType
      FrameType::CONTINUATION
    end

    def payload : Bytes
      @header_block
    end

    def self.parse_payload(stream_id : UInt32, flags : FrameFlags, payload : Bytes) : ContinuationFrame
      if stream_id == 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "CONTINUATION frame with stream ID 0")
      end

      ContinuationFrame.new(stream_id, payload, flags)
    end
  end
end
