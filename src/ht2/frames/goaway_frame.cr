module HT2
  class GoAwayFrame < Frame
    getter last_stream_id : UInt32
    getter error_code : ErrorCode
    getter debug_data : Bytes

    def initialize(@last_stream_id : UInt32, @error_code : ErrorCode, @debug_data : Bytes = Bytes.empty)
      super(0_u32, FrameFlags::None) # GOAWAY always on stream 0
    end

    def frame_type : FrameType
      FrameType::GOAWAY
    end

    def payload : Bytes
      bytes = Bytes.new(8 + @debug_data.size)

      # Last Stream ID (31 bits with reserved bit)
      bytes[0] = (@last_stream_id >> 24).to_u8 & 0x7F # Clear reserved bit
      bytes[1] = (@last_stream_id >> 16).to_u8
      bytes[2] = (@last_stream_id >> 8).to_u8
      bytes[3] = @last_stream_id.to_u8

      # Error Code (32 bits)
      error_value = @error_code.value
      bytes[4] = (error_value >> 24).to_u8
      bytes[5] = (error_value >> 16).to_u8
      bytes[6] = (error_value >> 8).to_u8
      bytes[7] = error_value.to_u8

      # Debug Data
      @debug_data.copy_to(bytes + 8, @debug_data.size)

      bytes
    end

    def self.parse_payload(stream_id : UInt32, flags : FrameFlags, payload : Bytes) : GoAwayFrame
      if stream_id != 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "GOAWAY frame with non-zero stream ID")
      end

      if payload.size < 8
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "GOAWAY payload too small")
      end

      # Last Stream ID (ignore reserved bit)
      last_stream_id = ((payload[0].to_u32 & 0x7F) << 24) |
                       (payload[1].to_u32 << 16) |
                       (payload[2].to_u32 << 8) |
                       payload[3].to_u32

      # Error Code
      error_value = (payload[4].to_u32 << 24) |
                    (payload[5].to_u32 << 16) |
                    (payload[6].to_u32 << 8) |
                    payload[7].to_u32

      error_code = ErrorCode.new(error_value)

      # Debug Data
      debug_data = payload[8..]

      GoAwayFrame.new(last_stream_id, error_code, debug_data)
    end
  end
end
