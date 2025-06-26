require "../spec_helper"
require "../../src/ht2"

describe "CONTINUATION Frame Integration" do
  it "handles HEADERS + CONTINUATION frames correctly" do
    # Create a pair of connected sockets
    server_socket, client_socket = IO::Memory.new, IO::Memory.new

    # Create server connection
    server_connection = HT2::Connection.new(server_socket, is_server: true)

    # Track headers received
    headers_received = false
    received_headers = nil

    server_connection.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
      headers_received = true
      received_headers = headers
    end

    # Write client preface
    client_socket.write(HT2::CONNECTION_PREFACE.to_slice)

    # Send SETTINGS frame
    settings_frame = HT2::SettingsFrame.new
    settings_frame.write_to(client_socket)

    # Send HEADERS frame without END_HEADERS
    headers_payload = Bytes[0x82, 0x87] # :method GET, :scheme https
    headers_frame = HT2::HeadersFrame.new(1_u32, headers_payload, HT2::FrameFlags::None)
    headers_frame.write_to(client_socket)

    # Send CONTINUATION frames
    cont1_payload = Bytes[0x84] # :path /
    cont1_frame = HT2::ContinuationFrame.new(1_u32, cont1_payload, HT2::FrameFlags::None)
    cont1_frame.write_to(client_socket)

    # Final CONTINUATION with END_HEADERS
    cont2_payload = Bytes[0x01, 0x00] # :authority ""
    cont2_frame = HT2::ContinuationFrame.new(1_u32, cont2_payload, HT2::FrameFlags::END_HEADERS)
    cont2_frame.write_to(client_socket)

    # Reset positions for reading
    client_socket.rewind
    server_socket.rewind

    # Create a mock socket that reads from client_socket and writes to server_socket
    mock_socket = MockSocket.new(client_socket, server_socket)

    # Replace the server connection's socket with our mock
    server_connection = HT2::Connection.new(mock_socket, is_server: true)
    server_connection.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
      headers_received = true
      received_headers = headers
    end

    # Start the connection (this will process the frames)
    spawn { server_connection.start }

    # Give it time to process
    sleep 100.milliseconds

    # Verify headers were received
    headers_received.should be_true
    received_headers.should_not be_nil

    headers = received_headers.not_nil!
    headers.find { |k, v| k == ":method" }.should eq({":method", "GET"})
    headers.find { |k, v| k == ":scheme" }.should eq({":scheme", "https"})
    headers.find { |k, v| k == ":path" }.should eq({":path", "/"})
    headers.find { |k, v| k == ":authority" }.should eq({":authority", ""})
  end

  it "rejects CONTINUATION without HEADERS" do
    server_socket, client_socket = IO::Memory.new, IO::Memory.new

    # Write preface and settings
    client_socket.write(HT2::CONNECTION_PREFACE.to_slice)
    settings_frame = HT2::SettingsFrame.new
    settings_frame.write_to(client_socket)

    # Send CONTINUATION without HEADERS (protocol error)
    cont_payload = Bytes[0x82]
    cont_frame = HT2::ContinuationFrame.new(1_u32, cont_payload, HT2::FrameFlags::END_HEADERS)
    cont_frame.write_to(client_socket)

    client_socket.rewind
    server_socket.rewind

    mock_socket = MockSocket.new(client_socket, server_socket)
    server_connection = HT2::Connection.new(mock_socket, is_server: true)

    connection_error = false
    spawn do
      begin
        server_connection.start
      rescue ex : HT2::ConnectionError
        connection_error = true
      end
    end

    sleep 100.milliseconds

    # Should have received a GOAWAY frame
    server_socket.rewind
    goaway_found = false

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

      if frame.is_a?(HT2::GoAwayFrame)
        goaway_found = true
        frame.error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
        break
      end
    end

    goaway_found.should be_true
  end
end

# Mock socket for testing
class MockSocket < IO
  def initialize(@read_io : IO, @write_io : IO)
  end

  def read(slice : Bytes) : Int32
    @read_io.read(slice)
  end

  def write(slice : Bytes) : Nil
    @write_io.write(slice)
  end

  def flush : Nil
    @write_io.flush if @write_io.responds_to?(:flush)
  end

  def close : Nil
    @read_io.close if @read_io.responds_to?(:close)
    @write_io.close if @write_io.responds_to?(:close)
  end
end
