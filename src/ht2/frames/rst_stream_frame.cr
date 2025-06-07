module HT2
  class RstStreamFrame < Frame
    getter error_code : ErrorCode

    def initialize(@stream_id : UInt32, @error_code : ErrorCode)
      super(@stream_id, FrameFlags::None)

      if @stream_id == 0
        raise ProtocolError.new("RST_STREAM frame cannot have stream ID 0")
      end
    end

    def frame_type : FrameType
      FrameType::RST_STREAM
    end

    def payload : Bytes
      bytes = Bytes.new(4)
      error_value = @error_code.value

      bytes[0] = (error_value >> 24).to_u8
      bytes[1] = (error_value >> 16).to_u8
      bytes[2] = (error_value >> 8).to_u8
      bytes[3] = error_value.to_u8

      bytes
    end

    def self.parse_payload(stream_id : UInt32, flags : FrameFlags, payload : Bytes) : RstStreamFrame
      if stream_id == 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "RST_STREAM frame with stream ID 0")
      end

      if payload.size != 4
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "RST_STREAM payload must be 4 bytes")
      end

      error_value = (payload[0].to_u32 << 24) |
                    (payload[1].to_u32 << 16) |
                    (payload[2].to_u32 << 8) |
                    payload[3].to_u32

      error_code = ErrorCode.new(error_value)

      RstStreamFrame.new(stream_id, error_code)
    end
  end
end
