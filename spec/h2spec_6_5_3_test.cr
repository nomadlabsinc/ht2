#!/usr/bin/env crystal

# Test for h2spec 6.5.3/1: Sends multiple values of SETTINGS_INITIAL_WINDOW_SIZE
# The test sends a SETTINGS frame with two SETTINGS_INITIAL_WINDOW_SIZE values:
# First sets to 100, then to 1. Expects the server to apply them in order.

require "../src/ht2"
require "socket"
require "openssl"

# Create TLS socket
begin
  tcp_client = TCPSocket.new("127.0.0.1", 8443)
  tcp_client.read_timeout = 5.seconds
  tcp_client.write_timeout = 5.seconds
rescue ex : Socket::ConnectError
  # ✗ Test FAILED: Cannot connect to server at 127.0.0.1:8443
  #   Make sure h2spec_server is running: ./examples/h2spec_server -p 8443
  exit 1
end

tls_context = OpenSSL::SSL::Context::Client.new
tls_context.verify_mode = OpenSSL::SSL::VerifyMode::NONE
tls_context.alpn_protocol = "h2"

client = OpenSSL::SSL::Socket::Client.new(tcp_client, context: tls_context)
client.sync = true

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
type = 0x04_u8 # SETTINGS
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

# Sent SETTINGS frame with duplicate INITIAL_WINDOW_SIZE (100, then 1)

# Helper function to read a frame from IO
def read_frame_from(io : IO) : HT2::Frame
  # Read frame header
  header_bytes = Bytes.new(HT2::Frame::HEADER_SIZE)
  io.read_fully(header_bytes)

  length, _, _, _ = HT2::Frame.parse_header(header_bytes)

  # Read full frame
  full_frame = Bytes.new(HT2::Frame::HEADER_SIZE + length)
  header_bytes.copy_to(full_frame)

  if length > 0
    io.read_fully(full_frame[HT2::Frame::HEADER_SIZE, length])
  end

  HT2::Frame.parse(full_frame)
rescue ex : IO::EOFError
  # ✗ Connection closed unexpectedly while reading frame
  raise ex
rescue ex : IO::TimeoutError
  # ✗ Timeout while reading frame
  raise ex
end

# Read server's SETTINGS frame
# Waiting for server SETTINGS frame...
server_settings = read_frame_from(client)
# Received: #{server_settings.class}

# Read frames until we get the SETTINGS ACK
loop do
  frame = read_frame_from(client)
  # Received frame: #{frame.class}
  if frame.is_a?(HT2::SettingsFrame)
    #   SETTINGS ACK=#{frame.flags.ack?}
    if frame.flags.ack?
      # Got SETTINGS ACK, breaking
      break
    end
  else
    #   Non-SETTINGS frame: #{frame.class}
    break
  end
end

# Send HEADERS frame with minimal required headers
# Create a simple HPACK encoder to encode headers
hpack_encoder = HT2::HPACK::Encoder.new

# Encode minimal HTTP/2 request headers
headers = [
  {":method", "GET"},
  {":path", "/"},
  {":scheme", "https"},
  {":authority", "127.0.0.1:8443"},
]

header_block = hpack_encoder.encode(headers)

headers_frame = HT2::HeadersFrame.new(
  stream_id: 1_u32,
  header_block: header_block,
  flags: HT2::FrameFlags::END_HEADERS | HT2::FrameFlags::END_STREAM
)
client.write(headers_frame.to_bytes)
client.flush

# Sent HEADERS frame

# Read response frames - expect HEADERS then DATA
begin
  response_frame = read_frame_from(client)
  if response_frame.is_a?(HT2::HeadersFrame)
    # Received HEADERS response frame

    # Now read DATA frame - expecting length 1
    data_frame = read_frame_from(client)
    if data_frame.is_a?(HT2::DataFrame)
      # Received DATA frame: length=#{data_frame.data.size}, flags=#{data_frame.flags}
      if data_frame.data.size == 1
        # ✓ Test PASSED: Server correctly applied settings in order (final window=1)
      else
        # ✗ Test FAILED: Expected DATA length=1, got length=#{data_frame.data.size}
      end
    else
      # ✗ Test FAILED: Expected DATA frame after HEADERS, got #{data_frame.class}
    end
  elsif response_frame.is_a?(HT2::DataFrame)
    # Received DATA frame directly: length=#{response_frame.data.size}, flags=#{response_frame.flags}
    if response_frame.data.size == 1
      # ✓ Test PASSED: Server correctly applied settings in order (final window=1)
    else
      # ✗ Test FAILED: Expected DATA length=1, got length=#{response_frame.data.size}
    end
  else
    # ✗ Test FAILED: Expected HEADERS or DATA frame, got #{response_frame.class}
  end
rescue ex
  # ✗ Test FAILED: #{ex.message}
ensure
  client.close rescue nil
  tcp_client.close rescue nil
end
