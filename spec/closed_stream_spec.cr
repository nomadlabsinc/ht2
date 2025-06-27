require "./spec_helper"

describe "Closed Stream Handling" do
  it "rejects RST_STREAM on idle stream" do
    client_io = IO::Memory.new
    server_io = IO::Memory.new

    # Write client preface
    client_io.write(HT2::CONNECTION_PREFACE.to_slice)

    # Send SETTINGS
    settings = HT2::SettingsFrame.new
    settings.write_to(client_io)

    # Send RST_STREAM for stream 1 that doesn't exist (idle)
    rst_frame = HT2::RstStreamFrame.new(1_u32, HT2::ErrorCode::CANCEL)
    rst_frame.write_to(client_io)

    # Reset for reading
    client_io.rewind

    # Create server connection
    mock_socket = MockBidirectionalSocket.new(client_io, server_io)
    connection = HT2::Connection.new(mock_socket, is_server: true)

    # Start connection in a fiber
    spawn { connection.start rescue nil }

    # Give it time to process
    sleep 100.milliseconds

    # Check what was written to server_io
    server_io.rewind
    goaway_found = false
    frames_seen = [] of HT2::Frame

    # Read all frames sent by server
    while server_io.pos < server_io.size
      remaining = server_io.size - server_io.pos
      break if remaining < 9 # Not enough for frame header

      # Peek at frame header to get length
      start_pos = server_io.pos
      header = Bytes.new(9)
      server_io.read(header)
      length = (header[0].to_u32 << 16) | (header[1].to_u32 << 8) | header[2].to_u32

      # Reset and read full frame
      server_io.pos = start_pos
      frame_size = 9 + length
      break if remaining < frame_size

      buffer = Bytes.new(frame_size)
      server_io.read(buffer)
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
