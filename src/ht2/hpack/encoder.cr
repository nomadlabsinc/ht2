module HT2
  module HPACK
    class Encoder
      alias Header = Tuple(String, String)

      getter dynamic_table : Array(Header)
      getter dynamic_table_size : UInt32
      getter max_dynamic_table_size : UInt32

      def initialize(@max_dynamic_table_size : UInt32 = DEFAULT_HEADER_TABLE_SIZE)
        @dynamic_table = Array(Header).new
        @dynamic_table_size = 0_u32
        @header_table_size_update = nil
      end

      def encode(headers : Array(Header)) : Bytes
        io = IO::Memory.new

        # Send table size update if needed
        if update = @header_table_size_update
          encode_integer(io, update, 5, 0x20_u8) # Dynamic table size update pattern
          @header_table_size_update = nil
        end

        headers.each do |name, value|
          encode_header(io, name, value)
        end

        io.to_slice
      end

      def max_table_size=(size : UInt32)
        @max_dynamic_table_size = size
        @header_table_size_update = size
        evict_entries
      end

      def update_dynamic_table_size(size : UInt32) : Nil
        self.max_table_size = size
      end

      private def encode_header(io : IO, name : String, value : String)
        # Try to find in combined table (static + dynamic)
        index = find_header(name, value)
        name_index = find_header_name(name) if index.nil?

        if index
          # Indexed header field
          encode_integer(io, index, 7, 0x80_u8) # Indexed pattern
        elsif name_index
          # Literal header field with name reference
          encode_integer(io, name_index, 6, 0x40_u8) # Literal with incremental indexing
          encode_string(io, value)
          add_to_dynamic_table(name, value)
        else
          # Literal header field with literal name
          io.write_byte(0x40_u8) # Literal with incremental indexing, new name (index = 0)
          encode_string(io, name)
          encode_string(io, value)
          add_to_dynamic_table(name, value)
        end
      end

      private def find_header(name : String, value : String) : UInt32?
        # Search static table
        STATIC_TABLE.each_with_index do |header, i|
          if header[0] == name && header[1] == value
            return (i + 1).to_u32
          end
        end

        # Search dynamic table
        @dynamic_table.each_with_index do |header, i|
          if header[0] == name && header[1] == value
            return (STATIC_TABLE_SIZE + i + 1).to_u32
          end
        end

        nil
      end

      private def find_header_name(name : String) : UInt32?
        # Search static table
        STATIC_TABLE.each_with_index do |header, i|
          if header[0] == name
            return (i + 1).to_u32
          end
        end

        # Search dynamic table
        @dynamic_table.each_with_index do |header, i|
          if header[0] == name
            return (STATIC_TABLE_SIZE + i + 1).to_u32
          end
        end

        nil
      end

      private def add_to_dynamic_table(name : String, value : String)
        entry = {name, value}
        entry_size = calculate_entry_size(name, value)

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

      private def encode_integer(io : IO, value : UInt32, prefix_bits : Int32, pattern : UInt8 = 0_u8)
        max_prefix = (1 << prefix_bits) - 1

        if value < max_prefix
          # Fits in prefix
          io.write_byte((pattern | value).to_u8)
        else
          # Doesn't fit in prefix
          io.write_byte((pattern | max_prefix).to_u8)
          value -= max_prefix

          while value >= 128
            io.write_byte((value & 0x7F | 0x80).to_u8)
            value >>= 7
          end

          io.write_byte(value.to_u8)
        end
      end

      private def encode_string(io : IO, value : String)
        # Always use Huffman encoding for better compression
        encoded = Huffman.encode(value)
        encode_integer(io, encoded.size.to_u32, 7, 0x80_u8) # Huffman flag
        io.write(encoded)
      end
    end
  end
end
