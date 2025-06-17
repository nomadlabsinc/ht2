require "../security"

module HT2
  module HPACK
    class Decoder
      alias Header = Tuple(String, String)

      getter dynamic_table : Array(Header)
      getter dynamic_table_size : UInt32
      property max_dynamic_table_size : UInt32
      property max_headers_size : UInt32

      def initialize(@max_dynamic_table_size : UInt32 = DEFAULT_HEADER_TABLE_SIZE,
                     @max_headers_size : UInt32 = Security::MAX_HEADER_LIST_SIZE)
        @dynamic_table = Array(Header).new
        @dynamic_table_size = 0_u32
        @total_headers_size = 0_u32
      end

      def decode(data : Bytes) : Array(Header)
        headers = Array(Header).new
        io = IO::Memory.new(data)
        @total_headers_size = 0_u32

        while io.pos < data.size
          decode_header(io, headers)
        end

        headers
      end

      private def decode_header(io : IO, headers : Array(Header))
        return if io.pos >= io.size

        first_byte = io.read_byte || return

        if first_byte & 0x80 != 0
          # Indexed header field
          index = decode_integer(io, first_byte, 7)
          header = get_header(index)
          # Ensure header name is lowercase (static table entries should already be lowercase)
          name = header[0].starts_with?(':') ? header[0] : header[0].downcase
          headers << {name, header[1]}
        elsif first_byte & 0x40 != 0
          # Literal header field with incremental indexing
          index = decode_integer(io, first_byte, 6)

          if index == 0
            # New name
            name = decode_string(io)
            value = decode_string(io)
          else
            # Indexed name
            name = get_header(index)[0]
            value = decode_string(io)
          end

          # Check decompressed size
          header_size = name.bytesize + value.bytesize
          @total_headers_size += header_size.to_u32

          if @total_headers_size > @max_headers_size
            raise DecompressionError.new("Headers size exceeds maximum: #{@total_headers_size} > #{@max_headers_size}")
          end

          # Validate header name
          Security.validate_header_name(name)

          # Convert header name to lowercase as required by HTTP/2
          name = name.downcase unless name.starts_with?(':')

          headers << {name, value}
          add_to_dynamic_table(name, value)
        elsif first_byte & 0x20 != 0
          # Dynamic table size update
          new_size = decode_integer(io, first_byte, 5)
          self.max_table_size = new_size
        else
          # Literal header field without indexing
          never_index = (first_byte & 0x10) != 0
          index = decode_integer(io, first_byte, never_index ? 4 : 6)

          if index == 0
            # New name
            name = decode_string(io)
            value = decode_string(io)
          else
            # Indexed name
            name = get_header(index)[0]
            value = decode_string(io)
          end

          # Check decompressed size
          header_size = name.bytesize + value.bytesize
          @total_headers_size += header_size.to_u32

          if @total_headers_size > @max_headers_size
            raise DecompressionError.new("Headers size exceeds maximum: #{@total_headers_size} > #{@max_headers_size}")
          end

          # Validate header name
          Security.validate_header_name(name)

          # Convert header name to lowercase as required by HTTP/2
          name = name.downcase unless name.starts_with?(':')

          headers << {name, value}
        end
      end

      private def get_header(index : UInt32) : Header
        if index == 0
          raise DecompressionError.new("Invalid header index: 0")
        elsif index <= STATIC_TABLE_SIZE
          STATIC_TABLE[index - 1]
        else
          dynamic_index = index - STATIC_TABLE_SIZE - 1
          if dynamic_index < @dynamic_table.size
            @dynamic_table[dynamic_index]
          else
            raise DecompressionError.new("Invalid header index: #{index}")
          end
        end
      end

      private def decode_integer(io : IO, first_byte : UInt8, prefix_bits : Int32) : UInt32
        max_prefix = (1 << prefix_bits) - 1
        value = (first_byte & max_prefix).to_u32

        if value < max_prefix
          return value
        end

        # Multi-byte integer
        shift = 0
        loop do
          byte = io.read_byte || raise DecompressionError.new("Incomplete integer")
          # Check for overflow before adding
          if shift > 28
            raise DecompressionError.new("Integer too large")
          end

          add_value = (byte & 0x7F).to_u32 << shift

          # Check if addition would overflow
          if value > UInt32::MAX - add_value
            raise DecompressionError.new("Integer overflow")
          end

          value += add_value
          shift += 7

          break if byte & 0x80 == 0
        end

        value
      end

      private def decode_string(io : IO) : String
        first_byte = io.read_byte || raise DecompressionError.new("Missing string length")
        huffman = (first_byte & 0x80) != 0
        length = decode_integer(io, first_byte, 7)

        if length > io.size - io.pos
          raise DecompressionError.new("String length exceeds remaining data")
        end

        data = Bytes.new(length)
        io.read_fully(data)

        if huffman
          Huffman.decode(data)
        else
          String.new(data)
        end
      end

      private def add_to_dynamic_table(name : String, value : String)
        entry = {name, value}
        entry_size = calculate_entry_size(name, value)

        # Check dynamic table entry limit
        if @dynamic_table.size >= Security::MAX_DYNAMIC_TABLE_ENTRIES
          # Remove oldest entries
          while @dynamic_table.size >= Security::MAX_DYNAMIC_TABLE_ENTRIES
            evicted = @dynamic_table.pop
            @dynamic_table_size -= calculate_entry_size(evicted[0], evicted[1])
          end
        end

        # Evict entries if needed
        while @dynamic_table_size + entry_size > @max_dynamic_table_size && !@dynamic_table.empty?
          evicted = @dynamic_table.pop
          @dynamic_table_size -= calculate_entry_size(evicted[0], evicted[1])
        end

        # Add new entry if it fits
        if entry_size <= @max_dynamic_table_size
          @dynamic_table.unshift(entry)
          @dynamic_table_size += entry_size
        end
      end

      def max_table_size=(size : UInt32)
        @max_dynamic_table_size = size
        evict_entries
      end

      private def evict_entries
        while @dynamic_table_size > @max_dynamic_table_size && !@dynamic_table.empty?
          evicted = @dynamic_table.pop
          @dynamic_table_size -= calculate_entry_size(evicted[0], evicted[1])
        end
      end

      private def calculate_entry_size(name : String, value : String) : UInt32
        # Entry size = name length + value length + 32 (RFC 7541 Section 4.1)
        (name.bytesize + value.bytesize + 32).to_u32
      end
    end
  end
end
