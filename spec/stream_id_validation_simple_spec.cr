require "./spec_helper"

describe "Stream ID Validation" do
  it "rejects even-numbered stream IDs from client" do
    client_socket = IO::Memory.new
    server_socket = IO::Memory.new

    # Write client preface
    client_socket.write(HT2::CONNECTION_PREFACE.to_slice)

    # Send SETTINGS
    settings = HT2::SettingsFrame.new
    settings.write_to(client_socket)

    # Send HEADERS frame with even stream ID (protocol error)
    headers_payload = encode_basic_headers("GET")
    send_headers_frame(client_socket, 2_u32, headers_payload, end_stream: true)

    # Reset for reading
    client_socket.rewind

    # Create server connection
    mock_socket = MockBidirectionalSocket.new(client_socket, server_socket)
    connection = HT2::Connection.new(mock_socket, is_server: true)

    # Start connection processing
    spawn { connection.start rescue nil }

    # Give it time to process
    sleep 100.milliseconds

    # Check what was written to server_socket
    server_socket.rewind
    goaway_found = false
    frames_seen = [] of HT2::Frame

    # Read all frames sent by server
    while server_socket.pos < server_socket.size
      remaining = server_socket.size - server_socket.pos
      break if remaining < 9 # Not enough for frame header

      # Peek at frame header to get length
      start_pos = server_socket.pos
      header = Bytes.new(9)
      server_socket.read(header)
      length = (header[0].to_u32 << 16) | (header[1].to_u32 << 8) | header[2].to_u32

      # Reset and read full frame
      server_socket.pos = start_pos
      frame_size = 9 + length
      break if remaining < frame_size

      buffer = Bytes.new(frame_size)
      server_socket.read(buffer)
      frame = HT2::Frame.parse(buffer)
      frames_seen << frame

      if frame.is_a?(HT2::GoAwayFrame)
        goaway_found = true
        frame.error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
        break
      end
    end

    # If no GOAWAY found, fail with helpful message
    unless goaway_found
      fail "Expected GOAWAY frame but got: #{frames_seen.map(&.class.name).join(", ")}"
    end
  end

  it "enforces stream ID ordering" do
    client_socket = IO::Memory.new
    server_socket = IO::Memory.new

    # Write client preface
    client_socket.write(HT2::CONNECTION_PREFACE.to_slice)

    # Send SETTINGS
    settings = HT2::SettingsFrame.new
    settings.write_to(client_socket)

    # Send HEADERS for stream 3
    headers3 = encode_basic_headers("GET")
    send_headers_frame(client_socket, 3_u32, headers3, end_stream: true)

    # Now send HEADERS for stream 1 (lower ID) - should fail
    headers1 = encode_basic_headers("GET")
    send_headers_frame(client_socket, 1_u32, headers1, end_stream: true)

    # Reset for reading
    client_socket.rewind

    # Create server connection
    mock_socket = MockBidirectionalSocket.new(client_socket, server_socket)
    connection = HT2::Connection.new(mock_socket, is_server: true)

    # Start connection processing
    spawn { connection.start rescue nil }

    # Give it time to process
    sleep 100.milliseconds

    # Check what was written to server_socket
    server_socket.rewind
    goaway_found = false
    frames_seen = [] of HT2::Frame

    # Read all frames sent by server
    while server_socket.pos < server_socket.size
      remaining = server_socket.size - server_socket.pos
      break if remaining < 9 # Not enough for frame header

      # Peek at frame header to get length
      start_pos = server_socket.pos
      header = Bytes.new(9)
      server_socket.read(header)
      length = (header[0].to_u32 << 16) | (header[1].to_u32 << 8) | header[2].to_u32

      # Reset and read full frame
      server_socket.pos = start_pos
      frame_size = 9 + length
      break if remaining < frame_size

      buffer = Bytes.new(frame_size)
      server_socket.read(buffer)
      frame = HT2::Frame.parse(buffer)
      frames_seen << frame

      if frame.is_a?(HT2::GoAwayFrame)
        goaway_found = true
        frame.error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
        break
      end
    end

    # If no GOAWAY found, fail with helpful message
    unless goaway_found
      fail "Expected GOAWAY frame but got: #{frames_seen.map(&.class.name).join(", ")}"
    end
  end
end

# Helper methods
private def send_headers_frame(socket : IO, stream_id : UInt32, payload : Bytes,
                               end_stream : Bool = false, end_headers : Bool = true)
  flags = HT2::FrameFlags::None
  flags = flags | HT2::FrameFlags::END_STREAM if end_stream
  flags = flags | HT2::FrameFlags::END_HEADERS if end_headers

  frame = HT2::HeadersFrame.new(stream_id, payload, flags)
  frame.write_to(socket)
  socket.flush if socket.responds_to?(:flush)
end

private def encode_basic_headers(method : String) : Bytes
  # Simple HPACK encoding for basic headers
  case method
  when "GET"
    # :method GET, :scheme https, :path /, :authority ""
    Bytes[0x82, 0x87, 0x84, 0x01, 0x00]
  when "POST"
    # :method POST, :scheme https, :path /, :authority ""
    Bytes[0x83, 0x87, 0x84, 0x01, 0x00]
  else
    raise "Unsupported method: #{method}"
  end
end
