module HT2
  module HPACK
    module Huffman
      extend self

      # Encode string using Huffman encoding
      def encode(data : String, output : IO::Memory? = nil) : Bytes
        encode(data.to_slice, output)
      end

      def encode(data : Bytes, output : IO::Memory? = nil) : Bytes
        bits = 0_u64
        bit_count = 0
        owned_output = output.nil?
        output ||= IO::Memory.new
        start_pos = output.pos

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

        if owned_output
          output.to_slice
        else
          # Return just the written portion
          output.to_slice[start_pos, output.pos - start_pos]
        end
      end

      # Decode Huffman encoded data
      def decode(data : Bytes) : String
        # First check for EOS pattern (30 consecutive 1s) in the raw data
        # This is required by RFC 7541 Section 5.2
        check_for_eos_pattern(data)

        String.build do |str|
          decode(data) { |byte| str.write_byte(byte) }
        end
      rescue ex : DecompressionError
        # Re-raise decompression errors with EOS check info
        Log.warn { "Huffman decode failed: #{ex.message}" }
        raise ex
      end

      # Check if the data contains the EOS pattern (30 consecutive 1s)
      private def check_for_eos_pattern(data : Bytes) : Nil
        return if data.size < 4 # Need at least 4 bytes for 30 bits

        Log.trace { "Checking for EOS pattern in #{data.size} bytes: #{data.hexstring}" }

        # Track consecutive 1s using a sliding window
        ones_count = 0
        max_ones = 0

        data.each_with_index do |byte, byte_idx|
          8.times do |bit_idx|
            if byte & (0x80 >> bit_idx) != 0
              ones_count += 1
              max_ones = ones_count if ones_count > max_ones
              if ones_count >= 30
                Log.error { "EOS pattern (30 consecutive 1s) found in Huffman data at byte #{byte_idx}, bit #{bit_idx}" }
                raise DecompressionError.new("EOS symbol found in Huffman data")
              end
            else
              ones_count = 0
            end
          end
        end

        Log.trace { "Max consecutive 1s found: #{max_ones}" }
      end

      def decode(data : Bytes, &)
        return if data.empty?

        # First check for EOS pattern (30 consecutive 1s) in the raw data
        # This is required by RFC 7541 Section 5.2
        check_for_eos_pattern(data)

        # Build decode tree for efficient decoding
        root = build_decode_tree
        node = root
        last_byte_index = data.size - 1
        last_symbol_bit = -1
        bits_processed = 0

        Log.debug { "Huffman decode: data.size=#{data.size}, hex=#{data.hexstring}" }

        # Check if this looks like it might contain EOS pattern
        if data.size >= 4
          # EOS is 0x3fffffff (30 bits of 1s)
          Log.debug { "Huffman decode: Checking for potential EOS pattern in data" }
        end

        data.each_with_index do |byte, byte_index|
          mask = 0x80_u8

          8.times do |bit_in_byte|
            if byte & mask != 0
              node = node.right || raise DecompressionError.new("Invalid Huffman sequence")
            else
              node = node.left || raise DecompressionError.new("Invalid Huffman sequence")
            end

            bits_processed += 1

            if value = node.value
              Log.trace { "Huffman decoded value: #{value}" }
              if value == 256 # EOS
                Log.error { "Huffman: EOS symbol detected! This is a compression error." }
                raise DecompressionError.new("EOS symbol found in Huffman data")
              end
              yield value.to_u8
              node = root

              # Track the bit position of the last completed symbol
              last_symbol_bit = byte_index * 8 + bit_in_byte
            end

            mask >>= 1
          end
        end

        # Validate padding if needed
        if node != root && data.size > 0
          # We ended in the middle of a symbol, which means we have padding
          # RFC 7541 Section 5.2: Any padding bits MUST be set to 1
          # Also: "A padding strictly longer than 7 bits MUST be treated as a decoding error."

          # Calculate padding length
          total_bits = data.size * 8

          # If no symbols were decoded, we need to check differently
          if last_symbol_bit < 0
            # No complete symbols were decoded
            # In this case, the entire input forms an incomplete symbol
            # which acts as padding. We only need to check that it's
            # a valid prefix of the EOS symbol (all 1s) and doesn't
            # exceed the allowed padding length.

            # For a single byte of 0xFF, this is 8 bits of 1s, which
            # forms a valid incomplete symbol (prefix of EOS). However,
            # the RFC says "padding longer than 7 bits" must be an error.
            # This is interpreted as: if we have more than 7 bits AFTER
            # the last complete symbol that don't form a complete symbol,
            # it's an error. Since we have no complete symbols, all 8 bits
            # are the incomplete symbol/padding.

            # Actually, let's check if ALL bits are 1s - if so, it's valid
            all_ones = data.all? { |b| b == 0xFF_u8 }

            if !all_ones
              # Check that trailing bits after incomplete symbol are 1s
              # This is more complex and handled below
            elsif bits_processed <= 7
              # 7 or fewer bits of padding is always OK
            elsif bits_processed == 8 && data.size == 1
              # Special case: single byte of 0xFF is allowed as it forms
              # a valid incomplete symbol (prefix of EOS)
            else
              raise DecompressionError.new("Padding longer than 7 bits")
            end
          else
            # Some symbols were decoded
            bits_used = last_symbol_bit + 1
            padding_bits = total_bits - bits_used

            Log.debug { "Huffman padding check: last_symbol_bit=#{last_symbol_bit}, total_bits=#{total_bits}, padding_bits=#{padding_bits}" }

            if padding_bits > 7
              raise DecompressionError.new("Padding longer than 7 bits")
            end
          end

          # To validate this, we need to check the bits after where we stopped
          # in our traversal. Since we know we're not at root, we know some bits
          # were processed but didn't complete a symbol.

          # The tricky part is that the incomplete symbol spans from the last
          # completed symbol to the end. We need to check that all bits after
          # this incomplete prefix are 1s.

          # If we have a last completed symbol, padding starts after it
          if last_symbol_bit >= 0
            # Calculate padding bits
            total_bits = data.size * 8
            # The bits after last_symbol_bit that form the incomplete symbol
            # plus any additional padding must all be 1s
            bits_after_last_symbol = total_bits - last_symbol_bit - 1

            if bits_after_last_symbol > 0
              # We need to verify these bits are consistent with being
              # a prefix of the EOS symbol (all 1s)

              # Check remaining bits in the byte containing last symbol
              last_symbol_byte_index = last_symbol_bit // 8
              last_symbol_bit_in_byte = last_symbol_bit % 8

              if last_symbol_byte_index == last_byte_index
                # All remaining bits are in the same byte
                remaining_bits_in_byte = 7 - last_symbol_bit_in_byte
                if remaining_bits_in_byte > 0
                  mask = (1 << remaining_bits_in_byte) - 1
                  if (data[last_byte_index] & mask) != mask
                    raise DecompressionError.new("Invalid Huffman padding (contains zeros)")
                  end
                end
              else
                # Check remaining bits in the byte with last symbol
                remaining_bits_in_symbol_byte = 7 - last_symbol_bit_in_byte
                if remaining_bits_in_symbol_byte > 0
                  mask = (1 << remaining_bits_in_symbol_byte) - 1
                  if (data[last_symbol_byte_index] & mask) != mask
                    raise DecompressionError.new("Invalid Huffman padding (contains zeros)")
                  end
                end

                # Check all complete bytes after the last symbol byte
                (last_symbol_byte_index + 1...last_byte_index).each do |i|
                  if data[i] != 0xFF
                    raise DecompressionError.new("Invalid Huffman padding (contains zeros)")
                  end
                end

                # Check the last byte
                if data[last_byte_index] != 0xFF
                  raise DecompressionError.new("Invalid Huffman padding (contains zeros)")
                end
              end
            end
          else
            # No symbols were completed, so all bits form an incomplete symbol
            # For this to be valid padding, ALL bits must be 1s (prefix of EOS)
            data.each do |byte|
              if byte != 0xFF
                raise DecompressionError.new("Invalid Huffman padding (contains zeros)")
              end
            end
          end
        elsif last_symbol_bit >= 0
          # We completed all symbols and are at root
          # Check if there's padding after the last symbol
          total_bits = data.size * 8
          bits_used = last_symbol_bit + 1
          padding_bits_count = total_bits - bits_used

          if padding_bits_count > 7
            raise DecompressionError.new("Padding longer than 7 bits")
          elsif padding_bits_count > 0
            last_byte = data[last_byte_index]
            # Create mask for the rightmost padding_bits_count bits
            padding_mask = (1 << padding_bits_count) - 1
            actual_padding = last_byte & padding_mask

            if actual_padding != padding_mask
              raise DecompressionError.new("Invalid Huffman padding (contains zeros)")
            end
          end
        end
      end

      # Count how many more bits are needed to reach a value from current node
      private def count_remaining_bits(node : DecodeNode, root : DecodeNode) : Int32
        return 0 if node == root

        # Try to find the shortest path to any value
        min_depth = 30 # Max Huffman code length

        queue = [{node, 0}]
        while !queue.empty?
          current, depth = queue.shift

          if current.value
            min_depth = depth if depth < min_depth
          else
            if left = current.left
              queue << {left, depth + 1}
            end
            if right = current.right
              queue << {right, depth + 1}
            end
          end
        end

        min_depth
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
