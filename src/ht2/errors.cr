module HT2
  # Error codes
  enum ErrorCode : UInt32
    NO_ERROR            = 0x00
    PROTOCOL_ERROR      = 0x01
    INTERNAL_ERROR      = 0x02
    FLOW_CONTROL_ERROR  = 0x03
    SETTINGS_TIMEOUT    = 0x04
    STREAM_CLOSED       = 0x05
    FRAME_SIZE_ERROR    = 0x06
    REFUSED_STREAM      = 0x07
    CANCEL              = 0x08
    COMPRESSION_ERROR   = 0x09
    CONNECT_ERROR       = 0x0a
    ENHANCE_YOUR_CALM   = 0x0b
    INADEQUATE_SECURITY = 0x0c
    HTTP_1_1_REQUIRED   = 0x0d
  end

  class Error < Exception
  end

  class ProtocolError < Error
  end

  class ConnectionError < Error
    getter code : ErrorCode

    def initialize(@code : ErrorCode, message : String? = nil)
      super(message || @code.to_s)
    end
  end

  class StreamError < Error
    getter code : ErrorCode
    getter stream_id : UInt32

    def initialize(@stream_id : UInt32, @code : ErrorCode, message : String? = nil)
      super(message || "Stream #{@stream_id}: #{@code}")
    end
  end

  class StreamClosedError < StreamError
    def initialize(stream_id : UInt32, message : String? = nil)
      super(stream_id, ErrorCode::STREAM_CLOSED, message)
    end
  end
end
