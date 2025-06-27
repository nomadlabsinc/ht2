module HT2
  # Validates content-length header against actual data received
  class ContentLengthValidator
    @expected_length : Int64?
    @received_length : Int64

    def initialize
      @expected_length = nil
      @received_length = 0_i64
    end

    # Set the expected content length from headers
    def set_expected_length(headers : Array(Tuple(String, String))) : Nil
      content_length_values = [] of String

      headers.each do |name, value|
        if name == "content-length"
          content_length_values << value
        end
      end

      # RFC 7540 Section 8.1.2.6: Only one content-length header is allowed
      if content_length_values.size > 1
        # Check if all values are identical
        unless content_length_values.all? { |v| v == content_length_values[0] }
          raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
            "Multiple content-length headers with different values")
        end
      end

      if content_length_values.size > 0
        value = content_length_values[0]

        # Validate content-length format
        unless value =~ /^\d+$/
          raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
            "Invalid content-length value: #{value}")
        end

        # Parse the length
        begin
          length = value.to_i64
          if length < 0
            raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
              "Negative content-length: #{length}")
          end
          @expected_length = length
        rescue
          raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
            "Invalid content-length value: #{value}")
        end
      end
    end

    # Add received data and validate against expected length
    def add_data(data : Bytes) : Nil
      @received_length += data.size

      # If we have an expected length and exceeded it, that's an error
      if expected = @expected_length
        if @received_length > expected
          raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
            "Received data (#{@received_length} bytes) exceeds content-length (#{expected} bytes)")
        end
      end
    end

    # Validate that we received exactly the expected amount when stream ends
    def validate_end_of_stream : Nil
      if expected = @expected_length
        if @received_length != expected
          raise StreamError.new(0_u32, ErrorCode::PROTOCOL_ERROR,
            "Content-length mismatch: expected #{expected} bytes, received #{@received_length} bytes")
        end
      end
    end

    # Check if content-length was specified
    def has_content_length? : Bool
      !@expected_length.nil?
    end

    # Get the expected content length
    def expected_length : Int64?
      @expected_length
    end

    # Get the received length so far
    def received_length : Int64
      @received_length
    end
  end
end
