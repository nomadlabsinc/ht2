module HT2
  module Security
    # Maximum sizes to prevent resource exhaustion
    MAX_HEADER_LIST_SIZE      =  8192_u32 # Maximum size of decompressed headers
    MAX_CONTINUATION_SIZE     = 32768_u32 # Maximum accumulated CONTINUATION frames
    MAX_DYNAMIC_TABLE_ENTRIES =  1000_u32 # Maximum entries in HPACK dynamic table
    MAX_PING_QUEUE_SIZE       =    10_u32 # Maximum pending ping responses
    MAX_SETTINGS_PER_SECOND   =    10_u32 # Rate limit for SETTINGS frames
    MAX_PING_PER_SECOND       =    10_u32 # Rate limit for PING frames
    MAX_RST_PER_SECOND        =   100_u32 # Rate limit for RST_STREAM frames
    MAX_PRIORITY_PER_SECOND   =   100_u32 # Rate limit for PRIORITY frames
    MAX_TOTAL_STREAMS         = 10000_u32 # Maximum total streams per connection

    # Window size limits
    MAX_WINDOW_SIZE = 0x7FFFFFFF_i64 # 2^31 - 1

    # Frame validation
    MAX_PADDING_LENGTH = 255_u32 # Maximum padding to prevent oracle attacks (UInt8 max)

    # Rate limiter for flood protection
    class RateLimiter
      def initialize(@max_per_second : UInt32)
        @window_start = Time.monotonic
        @count = 0_u32
      end

      def check : Bool
        now = Time.monotonic

        # Reset window if a second has passed
        if now - @window_start >= 1.second
          @window_start = now
          @count = 0
        end

        @count += 1
        @count <= @max_per_second
      end
    end

    # Checked arithmetic operations
    def self.checked_add(a : Int64, b : Int64) : Int64
      result = a &+ b

      # Check for overflow
      if (b > 0 && result < a) || (b < 0 && result > a)
        raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "Integer overflow in window calculation")
      end

      result
    end

    def self.validate_frame_size(size : UInt32, max_size : UInt32) : Nil
      if size > max_size
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "Frame size #{size} exceeds maximum #{max_size}")
      end
    end

    def self.validate_header_name(name : String) : Nil
      if name.empty?
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Empty header name")
      end

      # HTTP/2 allows more characters in header names, including :
      # Pseudo-headers start with : (e.g., :method, :path)
      name.each_char.with_index do |char, index|
        if index == 0 && char == ':'
          # Allow : at the beginning for pseudo-headers
          next
        end

        unless char.ascii_lowercase? || char.ascii_number? || char.in?('-', '_', '.', ':')
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid character in header name: #{char}")
        end
      end
    end
  end
end
