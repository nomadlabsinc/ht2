#!/usr/bin/env crystal

# Test for h2spec 6.5.3/1: Sends multiple values of SETTINGS_INITIAL_WINDOW_SIZE
# The test sends a SETTINGS frame with two SETTINGS_INITIAL_WINDOW_SIZE values:
# First sets to 100, then to 1. Expects the server to apply them in order.

require "../src/ht2"
require "socket"

client = TCPSocket.new("localhost", 8443)

# Send HTTP/2 connection preface
client.write(HT2::CONNECTION_PREFACE.to_slice)
client.flush

# Create SETTINGS frame with multiple INITIAL_WINDOW_SIZE values
settings_frame = HT2::SettingsFrame.new
settings_frame.settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE] = 100_u32
# Need to manually construct the frame to have duplicate parameters

# Manually build SETTINGS frame with duplicate parameters
frame_data = IO::Memory.new

# First INITIAL_WINDOW_SIZE = 100
frame_data.write_bytes(0x04_u16, IO::ByteFormat::BigEndian) # Parameter ID
frame_data.write_bytes(100_u32, IO::ByteFormat::BigEndian)  # Value

# Second INITIAL_WINDOW_SIZE = 1
frame_data.write_bytes(0x04_u16, IO::ByteFormat::BigEndian) # Parameter ID
frame_data.write_bytes(1_u32, IO::ByteFormat::BigEndian)    # Value

# Write frame header
length = frame_data.size
type = 0x04_u8  # SETTINGS
flags = 0x00_u8
stream_id = 0_u32

header = IO::Memory.new
header.write_bytes((length >> 16).to_u8)
header.write_bytes((length >> 8).to_u8)
header.write_bytes(length.to_u8)
header.write_bytes(type)
header.write_bytes(flags)
header.write_bytes(stream_id, IO::ByteFormat::BigEndian)

client.write(header.to_slice)
client.write(frame_data.to_slice)
client.flush

puts "Sent SETTINGS frame with duplicate INITIAL_WINDOW_SIZE (100, then 1)"

# Read server's SETTINGS frame
server_settings = HT2::Frame.read_from(client)
puts "Received: #{server_settings.class}"

# Read server's SETTINGS ACK
settings_ack = HT2::Frame.read_from(client)
puts "Received: #{settings_ack.class} ACK=#{settings_ack.as(HT2::SettingsFrame).flags.ack?}"

# Send HEADERS frame
headers_frame = HT2::HeadersFrame.new(
  stream_id: 1_u32,
  header_block: Bytes.new(0),  # Empty for now
  flags: HT2::FrameFlags::END_HEADERS | HT2::FrameFlags::END_STREAM
)
client.write(headers_frame.to_slice)
client.flush

puts "Sent HEADERS frame"

# Try to read DATA frame - expecting length 1
begin
  data_frame = HT2::Frame.read_from(client)
  if data_frame.is_a?(HT2::DataFrame)
    puts "Received DATA frame: length=#{data_frame.data.size}, flags=#{data_frame.flags}"
    if data_frame.data.size == 1
      puts "✓ Test PASSED: Server correctly applied settings in order (final window=1)"
    else
      puts "✗ Test FAILED: Expected DATA length=1, got length=#{data_frame.data.size}"
    end
  else
    puts "✗ Test FAILED: Expected DATA frame, got #{data_frame.class}"
  end
rescue ex
  puts "✗ Test FAILED: #{ex.message}"
end

client.close