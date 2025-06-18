require "./buffer_pool"
require "./zero_copy"

module HT2
  # Base frame structure for HTTP/2
  abstract class Frame
    HEADER_SIZE = 9

    getter length : UInt32
    getter type : FrameType
    getter flags : FrameFlags
    getter stream_id : UInt32

    def initialize(@stream_id : UInt32, @flags : FrameFlags = FrameFlags::None)
      @length = 0_u32
      @type = frame_type
    end

    abstract def frame_type : FrameType
    abstract def payload : Bytes

    # Serialize frame to bytes
    def to_bytes(buffer_pool : BufferPool? = nil) : Bytes
      payload_bytes = payload
      @length = payload_bytes.size.to_u32

      if @length > 0xFFFFFF
        raise ProtocolError.new("Frame payload too large: #{@length}")
      end

      total_size = HEADER_SIZE + payload_bytes.size
      bytes = buffer_pool ? buffer_pool.acquire(total_size) : Bytes.new(total_size)

      # Length (24 bits)
      bytes[0] = ((@length >> 16) & 0xFF).to_u8
      bytes[1] = ((@length >> 8) & 0xFF).to_u8
      bytes[2] = (@length & 0xFF).to_u8

      # Type (8 bits)
      bytes[3] = @type.value

      # Flags (8 bits)
      bytes[4] = @flags.value

      # Stream ID (32 bits with reserved bit)
      bytes[5] = ((@stream_id >> 24) & 0x7F).to_u8 # Clear reserved bit
      bytes[6] = ((@stream_id >> 16) & 0xFF).to_u8
      bytes[7] = ((@stream_id >> 8) & 0xFF).to_u8
      bytes[8] = (@stream_id & 0xFF).to_u8

      # Copy payload
      payload_bytes.copy_to((bytes + HEADER_SIZE).to_unsafe, payload_bytes.size)

      bytes
    end

    # Write frame directly to IO without intermediate buffer (zero-copy)
    def write_to(io : IO) : Nil
      ZeroCopy.write_frame(self, io)
    end

    # Write frame using provided header buffer (zero-copy)
    def write_to(io : IO, header_buffer : Bytes) : Nil
      ZeroCopy.write_frame_with_buffer(self, io, header_buffer)
    end

    # Parse frame header from bytes
    def self.parse_header(bytes : Bytes) : Tuple(UInt32, FrameType, FrameFlags, UInt32)
      if bytes.size < HEADER_SIZE
        raise ProtocolError.new("Frame header too small")
      end

      # Length (24 bits)
      length = (bytes[0].to_u32 << 16) | (bytes[1].to_u32 << 8) | bytes[2].to_u32

      # Type
      type = FrameType.new(bytes[3])

      # Flags
      flags = FrameFlags.new(bytes[4])

      # Stream ID (ignore reserved bit)
      stream_id = ((bytes[5].to_u32 & 0x7F) << 24) | (bytes[6].to_u32 << 16) |
                  (bytes[7].to_u32 << 8) | bytes[8].to_u32

      {length, type, flags, stream_id}
    end

    # Parse complete frame from bytes
    def self.parse(bytes : Bytes) : Frame
      length, type, flags, stream_id = parse_header(bytes)

      if bytes.size < HEADER_SIZE + length
        raise ProtocolError.new("Frame payload incomplete")
      end

      payload = bytes[HEADER_SIZE, length]

      case type
      when FrameType::DATA
        DataFrame.parse_payload(stream_id, flags, payload)
      when FrameType::HEADERS
        HeadersFrame.parse_payload(stream_id, flags, payload)
      when FrameType::PRIORITY
        PriorityFrame.parse_payload(stream_id, flags, payload)
      when FrameType::RST_STREAM
        RstStreamFrame.parse_payload(stream_id, flags, payload)
      when FrameType::SETTINGS
        SettingsFrame.parse_payload(stream_id, flags, payload)
      when FrameType::PUSH_PROMISE
        PushPromiseFrame.parse_payload(stream_id, flags, payload)
      when FrameType::PING
        PingFrame.parse_payload(stream_id, flags, payload)
      when FrameType::GOAWAY
        GoAwayFrame.parse_payload(stream_id, flags, payload)
      when FrameType::WINDOW_UPDATE
        WindowUpdateFrame.parse_payload(stream_id, flags, payload)
      when FrameType::CONTINUATION
        ContinuationFrame.parse_payload(stream_id, flags, payload)
      else
        # Unknown frame type - ignore
        UnknownFrame.new(stream_id, type, flags, payload)
      end
    end
  end

  # Unknown frame type
  class UnknownFrame < Frame
    getter unknown_type : FrameType
    getter payload_data : Bytes

    def initialize(@stream_id : UInt32, @unknown_type : FrameType, @flags : FrameFlags, @payload_data : Bytes)
      super(@stream_id, @flags)
      @type = @unknown_type
    end

    def frame_type : FrameType
      @unknown_type
    end

    def payload : Bytes
      @payload_data
    end
  end
end
