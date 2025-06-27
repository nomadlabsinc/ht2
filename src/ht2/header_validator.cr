module HT2
  # Validates HTTP/2 headers according to RFC 7540
  class HeaderValidator
    # Valid pseudo-headers for requests
    REQUEST_PSEUDO_HEADERS = {":method", ":scheme", ":authority", ":path"}

    # Valid pseudo-headers for responses
    RESPONSE_PSEUDO_HEADERS = {":status"}

    # All valid pseudo-headers
    ALL_PSEUDO_HEADERS = REQUEST_PSEUDO_HEADERS + RESPONSE_PSEUDO_HEADERS

    # Connection-specific headers that must be stripped
    CONNECTION_SPECIFIC_HEADERS = {
      "connection", "keep-alive", "proxy-connection", "transfer-encoding",
      "upgrade", "host",
    }

    # TE header is allowed only with "trailers" value
    TE_HEADER      = "te"
    TRAILERS_VALUE = "trailers"

    def initialize(@is_request : Bool = true, @is_trailers : Bool = false)
    end

    # Validates a set of headers and returns validated headers
    def validate(headers : Array(Tuple(String, String))) : Array(Tuple(String, String))
      validated_headers = [] of Tuple(String, String)
      pseudo_headers_seen = Set(String).new
      regular_header_seen = false
      content_length : String? = nil

      headers.each_with_index do |(name, value), index|
        # Validate header name format
        validate_header_name_format(name)

        # Check for uppercase letters in header names
        if name.chars.any?(&.ascii_uppercase?) && !name.starts_with?(':')
          raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
            "Header field name must be lowercase: #{name}")
        end

        if name.starts_with?(':')
          # Pseudo-headers are not allowed in trailers
          if @is_trailers
            raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
              "Pseudo-headers are not allowed in trailers: #{name}")
          end

          # Pseudo-header validation
          validate_pseudo_header(name, value, pseudo_headers_seen, regular_header_seen)
          pseudo_headers_seen << name
        else
          # Regular header validation
          regular_header_seen = true

          # Check for connection-specific headers
          if CONNECTION_SPECIFIC_HEADERS.includes?(name.downcase)
            # Connection-specific headers are forbidden in HTTP/2
            raise StreamError.new(0, ErrorCode::PROTOCOL_ERROR,
              "Connection-specific header field not allowed: #{name}")
          end

          # Special handling for TE header
          if name.downcase == TE_HEADER && value != TRAILERS_VALUE
            raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
              "TE header field with value other than 'trailers' is not allowed")
          end

          # Track content-length for validation
          if name.downcase == "content-length"
            if content_length
              # Duplicate content-length headers must have same value
              if content_length != value
                raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
                  "Multiple content-length headers with different values")
              end
            else
              content_length = value
              validate_content_length(value)
            end
          end
        end

        validated_headers << {name, value}
      end

      # Validate required pseudo-headers for requests (but not for trailers)
      if @is_request && !@is_trailers
        validate_required_request_headers(pseudo_headers_seen)
      end

      validated_headers
    end

    # Validates content-length header value
    def validate_content_length(value : String) : Nil
      unless value.chars.all?(&.ascii_number?)
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
          "Invalid content-length value: #{value}")
      end

      begin
        length = value.to_u64
      rescue
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
          "Invalid content-length value: #{value}")
      end
    end

    # Returns the content-length value if present
    def self.get_content_length(headers : Array(Tuple(String, String))) : UInt64?
      content_length_header = headers.find { |(name, _)| name.downcase == "content-length" }
      return nil unless content_length_header

      value = content_length_header[1]
      begin
        value.to_u64
      rescue
        nil
      end
    end

    private def validate_header_name_format(name : String) : Nil
      if name.empty?
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR, "Empty header name")
      end

      # For pseudo-headers, validate the part after the colon
      # For regular headers, validate the entire name
      start_index = name.starts_with?(':') ? 1 : 0

      if name.starts_with?(':') && name.size == 1
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
          "Invalid pseudo-header: empty name after colon")
      end

      # Validate characters according to RFC 7230 token definition
      name[start_index..].each_char do |char|
        unless char == '!' || char == '#' || char == '$' || char == '%' ||
               char == '&' || char == '\'' || char == '*' || char == '+' ||
               char == '-' || char == '.' || char.ascii_number? ||
               char.ascii_letter? || char == '^' || char == '_' ||
               char == '`' || char == '|' || char == '~'
          raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
            "Invalid character in header name: #{char}")
        end
      end
    end

    private def validate_pseudo_header(name : String, value : String,
                                       pseudo_headers_seen : Set(String),
                                       regular_header_seen : Bool) : Nil
      # Pseudo-headers must come before regular headers
      if regular_header_seen
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
          "Pseudo-header field after regular header field: #{name}")
      end

      # Check for unknown pseudo-headers
      unless ALL_PSEUDO_HEADERS.includes?(name)
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
          "Unknown pseudo-header field: #{name}")
      end

      # Check for request/response mismatch
      if @is_request && RESPONSE_PSEUDO_HEADERS.includes?(name)
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
          "Response pseudo-header in request: #{name}")
      elsif !@is_request && REQUEST_PSEUDO_HEADERS.includes?(name)
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
          "Request pseudo-header in response: #{name}")
      end

      # Check for duplicate pseudo-headers
      if pseudo_headers_seen.includes?(name)
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
          "Duplicate pseudo-header field: #{name}")
      end

      # Validate specific pseudo-header values
      case name
      when ":path"
        if value.empty?
          raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
            "Empty :path pseudo-header field")
        end
      when ":method"
        if value.empty?
          raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
            "Empty :method pseudo-header field")
        end
      when ":scheme"
        if value.empty?
          raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
            "Empty :scheme pseudo-header field")
        end
      when ":status"
        unless value.chars.all?(&.ascii_number?) && value.size == 3
          raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
            "Invalid :status pseudo-header field: #{value}")
        end
      end
    end

    private def validate_required_request_headers(pseudo_headers_seen : Set(String)) : Nil
      # Check for required pseudo-headers in requests
      unless pseudo_headers_seen.includes?(":method")
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
          "Missing required pseudo-header: :method")
      end

      unless pseudo_headers_seen.includes?(":scheme")
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
          "Missing required pseudo-header: :scheme")
      end

      unless pseudo_headers_seen.includes?(":path")
        raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
          "Missing required pseudo-header: :path")
      end

      # :authority is optional but recommended
    end

    # Checks if headers contain trailers
    def self.has_trailers?(headers : Array(Tuple(String, String))) : Bool
      headers.any? { |(name, value)| name.downcase == TE_HEADER && value == TRAILERS_VALUE }
    end
  end
end
