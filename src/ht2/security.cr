module HT2
  module Security
    # Maximum sizes to prevent resource exhaustion
    MAX_HEADER_LIST_SIZE      =   8192_u32 # Maximum size of decompressed headers
    MAX_CONTINUATION_SIZE     = 32_768_u32 # Maximum accumulated CONTINUATION frames
    MAX_CONTINUATION_FRAMES   =     20_u32 # Maximum number of CONTINUATION frames
    MAX_DYNAMIC_TABLE_ENTRIES =   1000_u32 # Maximum entries in HPACK dynamic table
    MAX_PING_QUEUE_SIZE       =     10_u32 # Maximum pending ping responses
    MAX_SETTINGS_PER_SECOND   =     10_u32 # Rate limit for SETTINGS frames
    MAX_PING_PER_SECOND       =     10_u32 # Rate limit for PING frames
    MAX_RST_PER_SECOND        =    100_u32 # Rate limit for RST_STREAM frames
    MAX_PRIORITY_PER_SECOND   =    100_u32 # Rate limit for PRIORITY frames
    MAX_TOTAL_STREAMS         = 10_000_u32 # Maximum total streams per connection

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

      # Check if it's a pseudo-header (starts with :)
      is_pseudo_header = name.starts_with?(':')

      # For pseudo-headers, validate the part after the colon
      # For regular headers, validate the entire name
      start_index = is_pseudo_header ? 1 : 0

      if is_pseudo_header && name.size == 1
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid pseudo-header: empty name after colon")
      end

      # Validate characters according to RFC 7230 token definition
      # token = 1*tchar
      # tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." /
      #         "0-9" / "A-Z" / "^" / "_" / "`" / "a-z" / "|" / "~"
      name[start_index..].each_char do |char|
        unless char == '!' || char == '#' || char == '$' || char == '%' ||
               char == '&' || char == '\'' || char == '*' || char == '+' ||
               char == '-' || char == '.' || char.ascii_number? ||
               char.ascii_letter? || char == '^' || char == '_' ||
               char == '`' || char == '|' || char == '~'
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Invalid character in header name: #{char}")
        end
      end
    end
  end
end
