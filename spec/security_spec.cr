require "./spec_helper"
require "../src/ht2/security"

describe HT2::Security do
  describe "CVE-2019-9513: Resource Loop" do
    it "validates frame size against MAX_FRAME_SIZE setting" do
      # The frame size validation is checked in the connection read_loop
      # For now, we'll test it directly at the validation level
      max_frame_size = HT2::DEFAULT_MAX_FRAME_SIZE
      oversized_length = max_frame_size + 1000

      expect_raises(HT2::ConnectionError, /Frame size \d+ exceeds maximum/) do
        HT2::Security.validate_frame_size(oversized_length, max_frame_size)
      end
    end
  end

  describe "CVE-2019-9516: 0-Length Headers Leak" do
    it "limits CONTINUATION frame accumulation" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, is_server: true)

      # Mock a large CONTINUATION accumulation
      connection.continuation_headers = IO::Memory.new
      connection.continuation_stream_id = 1_u32

      # Try to add data that would exceed limit
      large_data = Bytes.new(HT2::Security::MAX_CONTINUATION_SIZE + 1)
      frame = HT2::ContinuationFrame.new(1_u32, large_data, HT2::FrameFlags::None)

      expect_raises(HT2::ConnectionError, /CONTINUATION frames exceed size limit/) do
        connection.test_handle_continuation_frame(frame)
      end
    end
  end

  describe "CVE-2016-4462: HPACK Bomb" do
    it "limits decompressed header size" do
      decoder = HT2::HPACK::Decoder.new

      # Create compressed headers that expand to large size
      io = IO::Memory.new

      # Literal header with incremental indexing
      # Name: "x" (1 byte), Value: "y" * 10000 (10000 bytes)
      io.write_byte(0x40_u8) # Literal with incremental indexing, new name
      io.write_byte(0x01_u8) # Name length: 1
      io.write_byte('x'.ord.to_u8)

      # Value length: 10000 (encoded as integer)
      io.write_byte(0xFF_u8) # 127 with continuation
      io.write_byte(0xB1_u8) # (10000 - 127) & 0x7F | 0x80
      io.write_byte(0x4C_u8) # (10000 - 127) >> 7

      # Value: "y" * 10000
      io.write(("y" * 10000).to_slice)

      data = io.to_slice

      expect_raises(HT2::HPACK::DecompressionError, /Headers size exceeds maximum/) do
        decoder.decode(data)
      end
    end

    it "validates header names are not empty" do
      expect_raises(HT2::ConnectionError, /Empty header name/) do
        HT2::Security.validate_header_name("")
      end
    end

    it "validates header names contain only valid characters" do
      expect_raises(HT2::ConnectionError, /Invalid character in header name/) do
        HT2::Security.validate_header_name("content type") # Space not allowed
      end
      
      expect_raises(HT2::ConnectionError, /Invalid character in header name/) do
        HT2::Security.validate_header_name("content@type") # @ not allowed
      end

      # These should be valid (uppercase is allowed by RFC 7230)
      HT2::Security.validate_header_name("Content-Type")
      HT2::Security.validate_header_name("content-type")
      HT2::Security.validate_header_name("x-custom-header")
      HT2::Security.validate_header_name("header123")
      HT2::Security.validate_header_name("X-API-Key")
      HT2::Security.validate_header_name("!#$%&'*+-.^_`|~")  # All valid token chars
    end
  end

  describe "CVE-2019-9517: Internal Data Buffering" do
    it "prevents window update integer overflow" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, is_server: false)
      connection.window_size = HT2::Security::MAX_WINDOW_SIZE - 100

      # Try to overflow with large increment
      frame = HT2::WindowUpdateFrame.new(0, 200_u32)

      expect_raises(HT2::ConnectionError, /window overflow/) do
        connection.test_handle_window_update_frame(frame)
      end
    end

    it "rejects zero window increment" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, is_server: false)

      frame = HT2::WindowUpdateFrame.new(0, 0_u32)

      expect_raises(HT2::ConnectionError, /Window increment cannot be zero/) do
        connection.test_handle_window_update_frame(frame)
      end
    end

    it "uses checked arithmetic for window calculations" do
      # Test overflow detection
      expect_raises(HT2::ConnectionError, /Integer overflow/) do
        HT2::Security.checked_add(Int64::MAX - 10, 20)
      end

      # Test underflow detection
      expect_raises(HT2::ConnectionError, /Integer overflow/) do
        HT2::Security.checked_add(Int64::MIN + 10, -20)
      end

      # Normal operations should work
      result = HT2::Security.checked_add(100_i64, 50_i64)
      result.should eq(150_i64)
    end
  end

  describe "CVE-2019-9511: Data Flood" do
    it "enforces MAX_CONCURRENT_STREAMS when creating streams" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, is_server: true)

      # Set low limit for testing
      connection.remote_settings[HT2::SettingsParameter::MAX_CONCURRENT_STREAMS] = 2_u32

      # Create maximum allowed streams
      stream1 = connection.create_stream
      stream2 = connection.create_stream

      # Try to create one more
      expect_raises(HT2::ConnectionError, /Maximum concurrent streams/) do
        connection.create_stream
      end
    end

    it "enforces total stream limit" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, is_server: false)

      # Simulate reaching total stream limit
      connection.total_streams_count = HT2::Security::MAX_TOTAL_STREAMS

      expect_raises(HT2::ConnectionError, /Total stream limit reached/) do
        connection.test_get_or_create_stream(HT2::Security::MAX_TOTAL_STREAMS * 2 + 1)
      end
    end
  end

  describe "Rate limiting for flood protection" do
    it "rate limits SETTINGS frames (CVE-2019-9515)" do
      limiter = HT2::Security::RateLimiter.new(2_u32)

      # First two should pass
      limiter.check.should be_true
      limiter.check.should be_true

      # Third should fail
      limiter.check.should be_false

      # After a second, should reset
      sleep 1.1.seconds
      limiter.check.should be_true
    end

    it "prevents PING flood (CVE-2019-9512)" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, is_server: true)

      # Send many PINGs quickly
      11.times do |i|
        frame = HT2::PingFrame.new(Bytes.new(8, i.to_u8))
        if i < 10
          connection.test_handle_ping_frame(frame)
        else
          expect_raises(HT2::ConnectionError, /PING flood detected/) do
            connection.test_handle_ping_frame(frame)
          end
        end
      end
    end

    it "limits ping handler queue size" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, is_server: false)

      # Fill up ping handlers
      (HT2::Security::MAX_PING_QUEUE_SIZE + 5).times do |i|
        data = Bytes.new(8, i.to_u8)
        connection.ping_handlers[data] = Channel(Nil).new
      end

      # Queue should be limited
      connection.ping_handlers.size.should eq(HT2::Security::MAX_PING_QUEUE_SIZE + 5)

      # New ping should remove oldest
      frame = HT2::PingFrame.new(Bytes.new(8, 255_u8))
      connection.ping_rate_limiter = HT2::Security::RateLimiter.new(100_u32) # Allow for test
      connection.test_handle_ping_frame(frame)

      # Since shift was used in handle_ping_frame, size should have decreased
      connection.ping_handlers.size.should be < (HT2::Security::MAX_PING_QUEUE_SIZE + 5)
    end

    it "prevents RST_STREAM flood (CVE-2019-9514)" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, is_server: true)

      # Create streams
      100.times do |i|
        connection.streams[(i * 2 + 1).to_u32] = HT2::Stream.new((i * 2 + 1).to_u32, connection)
      end

      # Send many RST_STREAM frames
      101.times do |i|
        frame = HT2::RstStreamFrame.new((i * 2 + 1).to_u32, HT2::ErrorCode::CANCEL)
        if i < 100
          connection.test_handle_rst_stream_frame(frame)
        else
          expect_raises(HT2::ConnectionError, /RST_STREAM flood detected/) do
            connection.test_handle_rst_stream_frame(frame)
          end
        end
      end
    end

    it "prevents PRIORITY flood (CVE-2019-9516)" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, is_server: true)

      # Send many PRIORITY frames
      101.times do |i|
        priority = HT2::PriorityData.new(0_u32, 15_u8, false)
        frame = HT2::PriorityFrame.new((i * 2 + 1).to_u32, priority)

        if i < 100
          connection.test_handle_priority_frame(frame)
        else
          expect_raises(HT2::ConnectionError, /PRIORITY flood detected/) do
            connection.test_handle_priority_frame(frame)
          end
        end
      end
    end
  end

  describe "Padding oracle protection" do
    it "validates padding length" do
      # Test that maximum padding (255) is allowed
      frame = HT2::DataFrame.new(1_u32, Bytes.empty, HT2::FrameFlags::None, 255_u8)
      frame.padding.should eq(255_u8)

      # Test parsing frame where padding length equals remaining payload
      flags = HT2::FrameFlags::PADDED
      invalid_payload = Bytes.new(2)
      invalid_payload[0] = 1_u8 # padding length = 1, but only 1 byte remains after padding length byte

      expect_raises(HT2::ConnectionError, "Invalid frame format") do
        HT2::DataFrame.parse_payload(1_u32, flags, invalid_payload)
      end
    end

    it "uses consistent error messages for padding validation" do
      # All padding errors should return same message to prevent oracle attacks

      # Empty payload with PADDED flag
      flags = HT2::FrameFlags::PADDED
      expect_raises(HT2::ConnectionError, "Invalid frame format") do
        HT2::DataFrame.parse_payload(1_u32, flags, Bytes.empty)
      end

      # Padding >= payload size
      payload = Bytes.new(10)
      payload[0] = 10_u8 # padding length >= remaining bytes
      expect_raises(HT2::ConnectionError, "Invalid frame format") do
        HT2::DataFrame.parse_payload(1_u32, flags, payload)
      end

      # Padding larger than remaining bytes
      large_payload = Bytes.new(100)
      large_payload[0] = 100_u8 # padding length = 100, but only 99 bytes remain
      expect_raises(HT2::ConnectionError, "Invalid frame format") do
        HT2::DataFrame.parse_payload(1_u32, flags, large_payload)
      end
    end
  end

  describe "HPACK integer overflow protection" do
    it "prevents integer overflow in HPACK decoding" do
      decoder = HT2::HPACK::Decoder.new
      io = IO::Memory.new

      # Try to create an integer that would overflow
      # Start with indexed header field representation
      io.write_byte(0xFF_u8) # All bits set, needs continuation

      # Add continuation bytes that would cause overflow
      5.times do
        io.write_byte(0xFF_u8) # Maximum value with continuation bit
      end
      io.write_byte(0x7F_u8) # Final byte

      data = io.to_slice

      expect_raises(HT2::HPACK::DecompressionError, /Integer too large|Integer overflow/) do
        decoder.decode(data)
      end
    end
  end

  describe "Dynamic table limits" do
    it "limits number of entries in HPACK dynamic table" do
      decoder = HT2::HPACK::Decoder.new(4096_u32)
      io = IO::Memory.new

      # Add many small entries to exceed entry count limit
      (HT2::Security::MAX_DYNAMIC_TABLE_ENTRIES + 10).times do |i|
        # Literal with incremental indexing, new name
        io.write_byte(0x40_u8)
        io.write_byte(0x01_u8) # Name length: 1
        io.write_byte('a'.ord.to_u8)
        io.write_byte(0x01_u8) # Value length: 1
        io.write_byte((i % 256).to_u8)
      end

      data = io.to_slice
      decoder.decode(data)

      # Dynamic table should not exceed max entries
      decoder.dynamic_table.size.should be <= HT2::Security::MAX_DYNAMIC_TABLE_ENTRIES
    end
  end
end
