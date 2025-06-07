module HT2
  class WindowUpdateFrame < Frame
    getter window_size_increment : UInt32

    def initialize(@stream_id : UInt32, @window_size_increment : UInt32)
      super(@stream_id, FrameFlags::None)

      if @window_size_increment == 0
        raise ProtocolError.new("WINDOW_UPDATE increment cannot be 0")
      end

      if @window_size_increment > 0x7FFFFFFF
        raise ProtocolError.new("WINDOW_UPDATE increment too large")
      end
    end

    def frame_type : FrameType
      FrameType::WINDOW_UPDATE
    end

    def payload : Bytes
      bytes = Bytes.new(4)

      # Reserved bit (1 bit) + Window Size Increment (31 bits)
      bytes[0] = (@window_size_increment >> 24).to_u8 & 0x7F # Clear reserved bit
      bytes[1] = (@window_size_increment >> 16).to_u8
      bytes[2] = (@window_size_increment >> 8).to_u8
      bytes[3] = @window_size_increment.to_u8

      bytes
    end

    def self.parse_payload(stream_id : UInt32, flags : FrameFlags, payload : Bytes) : WindowUpdateFrame
      if payload.size != 4
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "WINDOW_UPDATE payload must be 4 bytes")
      end

      # Ignore reserved bit
      increment = ((payload[0].to_u32 & 0x7F) << 24) |
                  (payload[1].to_u32 << 16) |
                  (payload[2].to_u32 << 8) |
                  payload[3].to_u32

      if increment == 0
        if stream_id == 0
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "WINDOW_UPDATE increment of 0 on connection")
        else
          raise StreamError.new(stream_id, ErrorCode::PROTOCOL_ERROR, "WINDOW_UPDATE increment of 0")
        end
      end

      WindowUpdateFrame.new(stream_id, increment)
    end
  end
end
