require "./spec_helper"

describe "Content-Length Validation" do
  it "accepts valid content-length that matches data" do
    _, server_socket = run_test_scenario do |client_socket, _|
      # Send headers with content-length
      headers_payload = Bytes[
        0x83,                                                                               # :method POST
        0x87,                                                                               # :scheme https
        0x84,                                                                               # :path /
        0x01, 0x00,                                                                         # :authority ""
        0x00,                                                                               # Literal without indexing, new name
        0x0e,                                                                               # Name length 14
        0x63, 0x6f, 0x6e, 0x74, 0x65, 0x6e, 0x74, 0x2d, 0x6c, 0x65, 0x6e, 0x67, 0x74, 0x68, # "content-length"
        0x01,                                                                               # Value length 1
        0x35                                                                                # "5"
      ]
      send_headers_frame(client_socket, 1_u32, headers_payload, end_stream: false)

      # Send matching data
      data_frame = HT2::DataFrame.new(1_u32, Bytes[1, 2, 3, 4, 5], HT2::FrameFlags::END_STREAM)
      data_frame.write_to(client_socket)
    end

    # Should receive response, not error
    response = read_frames_until(server_socket, HT2::HeadersFrame)

    response.should_not be_nil
    response.should be_a(HT2::HeadersFrame)
  end

  it "rejects content-length mismatch (less data)" do
    _, server_socket = run_test_scenario do |client_socket, _|
      # Send headers with content-length 10
      headers_payload = encode_post_with_content_length("10")
      send_headers_frame(client_socket, 1_u32, headers_payload, end_stream: false)

      # Send less data than content-length
      data_frame1 = HT2::DataFrame.new(1_u32, Bytes[1, 2, 3], HT2::FrameFlags::None)
      data_frame1.write_to(client_socket)

      # End stream with mismatched length
      data_frame2 = HT2::DataFrame.new(1_u32, Bytes.empty, HT2::FrameFlags::END_STREAM)
      data_frame2.write_to(client_socket)
    end

    # Should receive RST_STREAM
    response = read_frames_until(server_socket, HT2::RstStreamFrame)
    response.should_not be_nil
    response.should be_a(HT2::RstStreamFrame)
    response.as(HT2::RstStreamFrame).error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
  end

  it "rejects content-length mismatch (more data)" do
    _, server_socket = run_test_scenario do |client_socket, _|
      # Send headers with content-length 3
      headers_payload = encode_post_with_content_length("3")
      send_headers_frame(client_socket, 1_u32, headers_payload, end_stream: false)

      # Send more data than content-length
      data_frame = HT2::DataFrame.new(1_u32, Bytes[1, 2, 3, 4, 5], HT2::FrameFlags::None)
      data_frame.write_to(client_socket)
    end

    # Should receive RST_STREAM
    response = read_frames_until(server_socket, HT2::RstStreamFrame)
    response.should_not be_nil
    response.should be_a(HT2::RstStreamFrame)
    response.as(HT2::RstStreamFrame).error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
  end

  it "accepts multiple DATA frames that sum to content-length" do
    _, server_socket = run_test_scenario do |client_socket, _|
      # Send headers with content-length 10
      headers_payload = encode_post_with_content_length("10")
      send_headers_frame(client_socket, 1_u32, headers_payload, end_stream: false)

      # Send data in multiple frames
      data_frame1 = HT2::DataFrame.new(1_u32, Bytes[1, 2, 3], HT2::FrameFlags::None)
      data_frame1.write_to(client_socket)

      data_frame2 = HT2::DataFrame.new(1_u32, Bytes[4, 5, 6, 7], HT2::FrameFlags::None)
      data_frame2.write_to(client_socket)

      data_frame3 = HT2::DataFrame.new(1_u32, Bytes[8, 9, 10], HT2::FrameFlags::END_STREAM)
      data_frame3.write_to(client_socket)
    end

    # Should receive response, not error
    response = read_frames_until(server_socket, HT2::HeadersFrame)
    response.should_not be_nil
    response.should be_a(HT2::HeadersFrame)
  end

  it "rejects multiple content-length headers with different values" do
    _, server_socket = run_test_scenario do |client_socket, _|
      # Send headers with multiple content-length values
      headers_payload = Bytes[
        0x83,                                                                               # :method POST
        0x87,                                                                               # :scheme https
        0x84,                                                                               # :path /
        0x01, 0x00,                                                                         # :authority ""
        0x00,                                                                               # Literal without indexing, new name
        0x0e,                                                                               # Name length 14
        0x63, 0x6f, 0x6e, 0x74, 0x65, 0x6e, 0x74, 0x2d, 0x6c, 0x65, 0x6e, 0x67, 0x74, 0x68, # "content-length"
        0x02,                                                                               # Value length 2
        0x31, 0x30,                                                                         # "10"
        0x00,                                                                               # Literal without indexing, new name
        0x0e,                                                                               # Name length 14
        0x63, 0x6f, 0x6e, 0x74, 0x65, 0x6e, 0x74, 0x2d, 0x6c, 0x65, 0x6e, 0x67, 0x74, 0x68, # "content-length"
        0x02,                                                                               # Value length 2
        0x32, 0x30                                                                          # "20"
      ]
      send_headers_frame(client_socket, 1_u32, headers_payload, end_stream: false)
    end

    # Should receive RST_STREAM
    response = read_frames_until(server_socket, HT2::RstStreamFrame)
    response.should_not be_nil
    response.should be_a(HT2::RstStreamFrame)
    response.as(HT2::RstStreamFrame).error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
  end

  it "accepts multiple content-length headers with same value" do
    _, server_socket = run_test_scenario do |client_socket, _|
      # Send headers with duplicate content-length values
      headers_payload = Bytes[
        0x83,                                                                               # :method POST
        0x87,                                                                               # :scheme https
        0x84,                                                                               # :path /
        0x01, 0x00,                                                                         # :authority ""
        0x00,                                                                               # Literal without indexing, new name
        0x0e,                                                                               # Name length 14
        0x63, 0x6f, 0x6e, 0x74, 0x65, 0x6e, 0x74, 0x2d, 0x6c, 0x65, 0x6e, 0x67, 0x74, 0x68, # "content-length"
        0x01,                                                                               # Value length 1
        0x35,                                                                               # "5"
        0x00,                                                                               # Literal without indexing, new name
        0x0e,                                                                               # Name length 14
        0x63, 0x6f, 0x6e, 0x74, 0x65, 0x6e, 0x74, 0x2d, 0x6c, 0x65, 0x6e, 0x67, 0x74, 0x68, # "content-length"
        0x01,                                                                               # Value length 1
        0x35                                                                                # "5"
      ]
      send_headers_frame(client_socket, 1_u32, headers_payload, end_stream: false)

      # Send matching data
      data_frame = HT2::DataFrame.new(1_u32, Bytes[1, 2, 3, 4, 5], HT2::FrameFlags::END_STREAM)
      data_frame.write_to(client_socket)
    end

    # Should receive response, not error
    response = read_frames_until(server_socket, HT2::HeadersFrame)
    response.should_not be_nil
    response.should be_a(HT2::HeadersFrame)
  end

  it "rejects invalid content-length format" do
    _, server_socket = run_test_scenario do |client_socket, _|
      # Send headers with invalid content-length
      headers_payload = encode_post_with_content_length("abc")
      send_headers_frame(client_socket, 1_u32, headers_payload, end_stream: false)
    end

    # Should receive RST_STREAM
    response = read_frames_until(server_socket, HT2::RstStreamFrame)
    response.should_not be_nil
    response.should be_a(HT2::RstStreamFrame)
    response.as(HT2::RstStreamFrame).error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
  end

  it "rejects negative content-length" do
    _, server_socket = run_test_scenario do |client_socket, _|
      # Send headers with negative content-length
      headers_payload = encode_post_with_content_length("-5")
      send_headers_frame(client_socket, 1_u32, headers_payload, end_stream: false)
    end

    # Should receive RST_STREAM
    response = read_frames_until(server_socket, HT2::RstStreamFrame)
    response.should_not be_nil
    response.should be_a(HT2::RstStreamFrame)
    response.as(HT2::RstStreamFrame).error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
  end

  it "rejects END_STREAM with non-zero content-length in headers" do
    _, server_socket = run_test_scenario do |client_socket, _|
      # Send headers with content-length 10 and END_STREAM
      headers_payload = encode_post_with_content_length("10")
      send_headers_frame(client_socket, 1_u32, headers_payload, end_stream: true)
    end

    # Should receive RST_STREAM
    response = read_frames_until(server_socket, HT2::RstStreamFrame)
    response.should_not be_nil
    response.should be_a(HT2::RstStreamFrame)
    response.as(HT2::RstStreamFrame).error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
  end

  it "allows END_STREAM with zero content-length" do
    _, server_socket = run_test_scenario do |client_socket, _|
      # Send headers with content-length 0 and END_STREAM
      headers_payload = encode_post_with_content_length("0")
      send_headers_frame(client_socket, 1_u32, headers_payload, end_stream: true)
    end

    # Should receive response, not error
    response = read_frames_until(server_socket, HT2::HeadersFrame)
    response.should_not be_nil
    response.should be_a(HT2::HeadersFrame)
  end

  it "handles requests without content-length" do
    _, server_socket = run_test_scenario do |client_socket, _|
      # Send POST without content-length
      headers_payload = encode_basic_headers("POST")
      send_headers_frame(client_socket, 1_u32, headers_payload, end_stream: false)

      # Can send any amount of data
      data_frame1 = HT2::DataFrame.new(1_u32, Bytes[1, 2, 3, 4, 5], HT2::FrameFlags::None)
      data_frame1.write_to(client_socket)

      data_frame2 = HT2::DataFrame.new(1_u32, Bytes[6, 7, 8], HT2::FrameFlags::END_STREAM)
      data_frame2.write_to(client_socket)
    end

    # Should receive response, not error
    response = read_frames_until(server_socket, HT2::HeadersFrame)
    response.should_not be_nil
    response.should be_a(HT2::HeadersFrame)
  end
end

# Helper methods
private def setup_test_sockets
  client_socket = IO::Memory.new
  server_socket = IO::Memory.new

  # Write client preface
  client_socket.write(HT2::CONNECTION_PREFACE.to_slice)

  # Send SETTINGS
  settings = HT2::SettingsFrame.new
  settings.write_to(client_socket)

  {client_socket, server_socket}
end

private def run_server(client_socket : IO::Memory, server_socket : IO::Memory)
  # Reset for reading
  client_socket.rewind

  # Create server connection
  mock_socket = MockBidirectionalSocket.new(client_socket, server_socket)
  connection = HT2::Connection.new(mock_socket, is_server: true)

  # Set up a simple handler that responds with 200 OK
  connection.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
    # Send a simple 200 OK response
    response_headers = [
      {":status", "200"},
      {"content-type", "text/plain"},
    ]
    stream.send_headers(response_headers, true)
  end

  # Start connection processing
  spawn { connection.start rescue nil }

  # Wait for initialization
  sleep 50.milliseconds
end

# Helper to run a test scenario
private def run_test_scenario(&)
  client_socket, server_socket = setup_test_sockets

  # Execute the test setup (writing frames)
  yield client_socket, server_socket

  # Start the server
  run_server(client_socket, server_socket)

  # Return the sockets for reading responses
  {client_socket, server_socket}
end

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

private def encode_post_with_content_length(length : String) : Bytes
  # POST headers with content-length
  # Using literal header field without indexing (0x00 prefix with 4-bit prefix)
  headers = IO::Memory.new
  headers.write_byte(0x83_u8) # :method POST
  headers.write_byte(0x87_u8) # :scheme https
  headers.write_byte(0x84_u8) # :path /
  headers.write_byte(0x01_u8) # :authority with 1 byte
  headers.write_byte(0x00_u8) # empty authority value

  # Literal header without indexing - content-length
  headers.write_byte(0x00_u8) # Literal without indexing, new name
  headers.write_byte(0x0e_u8) # Name length 14
  headers.write("content-length".to_slice)
  headers.write_byte(length.bytesize.to_u8) # Value length
  headers.write(length.to_slice)

  headers.to_slice
end

private def read_frame_with_timeout(socket : IO, timeout : Time::Span = 100.milliseconds) : HT2::Frame?
  socket.rewind if socket.responds_to?(:rewind)

  deadline = Time.monotonic + timeout

  while Time.monotonic < deadline
    if socket.size > 0
      begin
        # Read available bytes
        buffer = Bytes.new(socket.size)
        bytes_read = socket.read(buffer)
        if bytes_read > 0
          return HT2::Frame.parse(buffer[0, bytes_read])
        end
      rescue
        # Frame not ready yet
      end
    end
    sleep 10.milliseconds
  end

  nil
end

private def read_frames_until(socket : IO, frame_type : HT2::Frame.class, timeout : Time::Span = 200.milliseconds) : HT2::Frame?
  socket.rewind if socket.responds_to?(:rewind)

  deadline = Time.monotonic + timeout
  last_size = 0

  while Time.monotonic < deadline
    # Check if new data has arrived
    current_size = socket.size
    if current_size > last_size
      last_size = current_size
      socket.rewind if socket.responds_to?(:rewind)

      # Read all available frames
      while socket.pos < socket.size
        remaining = socket.size - socket.pos
        break if remaining < 9 # Not enough for frame header

        # Peek at frame header to get length
        start_pos = socket.pos
        header = Bytes.new(9)
        socket.read(header)
        length = (header[0].to_u32 << 16) | (header[1].to_u32 << 8) | header[2].to_u32

        # Reset and read full frame
        socket.pos = start_pos
        frame_size = 9 + length
        break if remaining < frame_size

        buffer = Bytes.new(frame_size)
        socket.read(buffer)
        frame = HT2::Frame.parse(buffer)

        # Return if it's the frame type we're looking for
        return frame if frame.class == frame_type
      end
    end

    sleep 10.milliseconds
  end

  nil
end
