module HT2
  module HPACK
    module Huffman
      extend self

      # Encode string using Huffman encoding
      def encode(data : String) : Bytes
        encode(data.to_slice)
      end

      def encode(data : Bytes) : Bytes
        bits = 0_u64
        bit_count = 0
        output = IO::Memory.new

        data.each do |byte|
          code, length = HUFFMAN_TABLE[byte.to_i]

          bits = (bits << length) | code
          bit_count += length

          while bit_count >= 8
            bit_count -= 8
            output.write_byte((bits >> bit_count).to_u8)
            bits &= (1_u64 << bit_count) - 1
          end
        end

        # Pad with 1s if needed (RFC 7541 Section 5.2)
        if bit_count > 0
          bits = (bits << (8 - bit_count)) | ((1_u64 << (8 - bit_count)) - 1)
          output.write_byte(bits.to_u8)
        end

        output.to_slice
      end

      # Decode Huffman encoded data
      def decode(data : Bytes) : String
        String.build do |str|
          decode(data) { |byte| str.write_byte(byte) }
        end
      end

      def decode(data : Bytes, &)
        return if data.empty?

        # Build decode tree for efficient decoding
        root = build_decode_tree
        node = root

        data.each do |byte|
          mask = 0x80_u8

          8.times do
            if byte & mask != 0
              node = node.right || raise DecompressionError.new("Invalid Huffman sequence")
            else
              node = node.left || raise DecompressionError.new("Invalid Huffman sequence")
            end

            if value = node.value
              if value == 256 # EOS
                return
              end
              yield value.to_u8
              node = root
            end

            mask >>= 1
          end
        end

        # Check for incomplete sequence
        # The padding bits (all 1s) should leave us at a node that can be safely ignored
        # per RFC 7541 Section 5.2
      end

      private class DecodeNode
        property left : DecodeNode?
        property right : DecodeNode?
        property value : Int32?

        def initialize(@value = nil)
        end
      end

      private def build_decode_tree : DecodeNode
        root = DecodeNode.new

        HUFFMAN_TABLE.each do |value, (code, length)|
          node = root
          mask = 1 << (length - 1)

          length.times do
            if code & mask != 0
              node.right ||= DecodeNode.new
              if next_node = node.right
                node = next_node
              else
                raise Error.new("Failed to create decode tree")
              end
            else
              node.left ||= DecodeNode.new
              if next_node = node.left
                node = next_node
              else
                raise Error.new("Failed to create decode tree")
              end
            end
            mask >>= 1
          end

          node.value = value
        end

        root
      end
    end
  end
end
