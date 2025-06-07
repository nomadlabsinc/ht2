require "./ht2/errors"
require "./ht2/connection"
require "./ht2/context"
require "./ht2/frames"
require "./ht2/hpack"
require "./ht2/request"
require "./ht2/response"
require "./ht2/server"
require "./ht2/stream"

module HT2
  VERSION = "0.1.0"

  # HTTP/2 connection preface
  CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

  # Default settings
  DEFAULT_HEADER_TABLE_SIZE      =  4096_u32
  DEFAULT_MAX_CONCURRENT_STREAMS =   100_u32
  DEFAULT_INITIAL_WINDOW_SIZE    = 65535_u32
  DEFAULT_MAX_FRAME_SIZE         = 16384_u32
  DEFAULT_MAX_HEADER_LIST_SIZE   =  8192_u32

  # Frame types
  enum FrameType : UInt8
    DATA          = 0x00
    HEADERS       = 0x01
    PRIORITY      = 0x02
    RST_STREAM    = 0x03
    SETTINGS      = 0x04
    PUSH_PROMISE  = 0x05
    PING          = 0x06
    GOAWAY        = 0x07
    WINDOW_UPDATE = 0x08
    CONTINUATION  = 0x09
  end

  # Frame flags
  @[Flags]
  enum FrameFlags : UInt8
    END_STREAM  = 0x01
    END_HEADERS = 0x04
    PADDED      = 0x08
    PRIORITY    = 0x20
    ACK         = 0x01
  end

  # Error codes moved to errors.cr

  # Settings parameters
  enum SettingsParameter : UInt16
    HEADER_TABLE_SIZE      = 0x01
    ENABLE_PUSH            = 0x02
    MAX_CONCURRENT_STREAMS = 0x03
    INITIAL_WINDOW_SIZE    = 0x04
    MAX_FRAME_SIZE         = 0x05
    MAX_HEADER_LIST_SIZE   = 0x06
  end

  # Error classes moved to errors.cr
end
