#!/usr/bin/env crystal

# Test for h2spec 6.9.2/2: Sends a SETTINGS frame for window size to be negative
# The test:
# 1. Sets initial window size to 3
# 2. Sends HEADERS frame
# 3. Receives DATA frame (consumes part of window)
# 4. Sets window size to 2 (making effective window negative)
# 5. Sends WINDOW_UPDATE with increment 2
# 6. Expects a 1-byte DATA frame

require "../src/ht2"
require "socket"
require "log"

Log.setup_from_env

client = TCPSocket.new("localhost", 8443)

# Send HTTP/2 connection preface
client.write(HT2::CONNECTION_PREFACE.to_slice)
client.flush

# Send SETTINGS frame with INITIAL_WINDOW_SIZE = 3
settings1 = HT2::SettingsFrame.new
settings1.settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE] = 3_u32
client.write(settings1.to_slice)
client.flush

# Sent SETTINGS with INITIAL_WINDOW_SIZE=3

# Read server's SETTINGS frame
server_settings = HT2::Frame.read_from(client)
# Received: #{server_settings.class}

# Read server's SETTINGS ACK
settings_ack1 = HT2::Frame.read_from(client)
# Received: #{settings_ack1.class} ACK=#{settings_ack1.as(HT2::SettingsFrame).flags.ack?}

# Send our SETTINGS ACK
ack_frame = HT2::SettingsFrame.new(flags: HT2::FrameFlags::ACK)
client.write(ack_frame.to_slice)
client.flush

# Send HEADERS frame (request)
encoder = HT2::HPACK::Encoder.new(4096_u32)
headers = [
  {":method", "GET"},
  {":path", "/"},
  {":scheme", "http"},
  {":authority", "localhost:8443"},
]
header_block = encoder.encode(headers)

headers_frame = HT2::HeadersFrame.new(
  stream_id: 1_u32,
  header_block: header_block,
  flags: HT2::FrameFlags::END_HEADERS
)
client.write(headers_frame.to_slice)
client.flush

# Sent HEADERS frame (stream 1)

# Read initial response - should get headers and maybe some data
data_received = 0
headers_received = false

2.times do
  frame = HT2::Frame.read_from(client)
  case frame
  when HT2::HeadersFrame
    # Received HEADERS frame
    headers_received = true
  when HT2::DataFrame
    # Received DATA frame: length=#{frame.data.size}
    data_received += frame.data.size
  end

  break if headers_received && data_received > 0
end

# Total data received so far: #{data_received} bytes

# Now change INITIAL_WINDOW_SIZE to 2 (which should make window negative)
settings2 = HT2::SettingsFrame.new
settings2.settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE] = 2_u32
client.write(settings2.to_slice)
client.flush

# Sent SETTINGS with INITIAL_WINDOW_SIZE=2 (window should be negative: 2 - #{data_received} = #{2 - data_received})

# Read SETTINGS ACK
settings_ack2 = HT2::Frame.read_from(client)
# Received: #{settings_ack2.class} ACK=#{settings_ack2.as(HT2::SettingsFrame).flags.ack?}

# Send WINDOW_UPDATE with increment 2
window_update = HT2::WindowUpdateFrame.new(stream_id: 1_u32, window_size_increment: 2_u32)
client.write(window_update.to_slice)
client.flush

# Sent WINDOW_UPDATE with increment=2 for stream 1

# Try to read DATA frame - expecting length 1
timeout = 2.seconds
start_time = Time.monotonic

while Time.monotonic - start_time < timeout
  begin
    frame = HT2::Frame.read_from(client)

    case frame
    when HT2::DataFrame
      if frame.stream_id == 1
        # Received DATA frame: length=#{frame.data.size}, flags=#{frame.flags.value}
        if frame.data.size == 1 && !frame.flags.end_stream?
          # ✓ Test PASSED: Server correctly tracked negative window and sent 1 byte after update
        else
          # ✗ Test FAILED: Expected DATA(length:1, flags:0x00), got DATA(length:#{frame.data.size}, flags:0x#{frame.flags.value.to_s(16).rjust(2, '0')})
        end
        break
      end
    when HT2::GoAwayFrame
      # Received GOAWAY: last_stream_id=#{frame.last_stream_id}, error_code=#{frame.error_code}
      break
    else
      # Received unexpected frame: #{frame.class}
    end
  rescue IO::TimeoutError
    # Timeout waiting for frames
    break
  rescue ex
    # Error reading frame: #{ex.message}
    break
  end
end

client.close
