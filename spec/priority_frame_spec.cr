require "./spec_helper"

describe "PRIORITY Frame Handling (RFC 9113 Deprecation)" do
  it "ignores PRIORITY frames and does not affect stream processing" do
    client_mock_socket, server_connection = run_test_scenario do |client_conn_socket, server_conn_socket|
      # Send client preface
      client_conn_socket.write(HT2::CONNECTION_PREFACE.to_slice)

      # Send client SETTINGS
      settings = HT2::SettingsFrame.new
      settings.write_to(client_conn_socket)

      # Send a HEADERS frame to open a stream
      headers_payload = encode_basic_headers("GET")
      send_headers_frame(client_conn_socket, 1_u32, headers_payload, end_stream: true)

      # Send a PRIORITY frame for stream 1 (should be ignored)
      # Create PRIORITY frame payload manually (5 bytes: E + 31-bit stream_dependency + 8-bit weight)
      priority_payload = Bytes[
        0x00, 0x00, 0x00, 0x00, # stream dependency (not exclusive, stream 0)
        0xc8                    # weight 200
      ]
      priority_frame = HT2::UnknownFrame.new(1_u32, HT2::FrameType::PRIORITY, HT2::FrameFlags::None, priority_payload)
      priority_frame.write_to(client_conn_socket)

      # Send another HEADERS frame for stream 3
      headers_payload_2 = encode_basic_headers("GET")
      send_headers_frame(client_conn_socket, 3_u32, headers_payload_2, end_stream: true)
    end

    # Expect responses for both streams, no errors
    response1 = read_frames_until(client_mock_socket, HT2::HeadersFrame)
    response1.should_not be_nil
    response1.should be_a(HT2::HeadersFrame)
    response1.as(HT2::HeadersFrame).stream_id.should eq(1_u32)

    response2 = read_frames_until(client_mock_socket, HT2::HeadersFrame)
    response2.should_not be_nil
    response2.should be_a(HT2::HeadersFrame)
    response2.as(HT2::HeadersFrame).stream_id.should eq(3_u32)

    # Ensure no RST_STREAM or GOAWAY frames were sent due to PRIORITY
    error_frame = read_frame_with_timeout(client_mock_socket, timeout: 50.milliseconds)
    error_frame.should be_nil
  end

  it "ignores priority information in HEADERS frames" do
    client_mock_socket, server_connection = run_test_scenario do |client_conn_socket, server_conn_socket|
      # Send client preface
      client_conn_socket.write(HT2::CONNECTION_PREFACE.to_slice)

      # Send client SETTINGS
      settings = HT2::SettingsFrame.new
      settings.write_to(client_conn_socket)

      # Send HEADERS frame with PRIORITY flag set and priority data
      headers_payload = Bytes[
        0x82,       # :method GET
        0x87,       # :scheme https
        0x84,       # :path /
        0x01, 0x00, # :authority ""
      ]
      # Manually add priority data to payload (exclusive, stream 0, weight 200)
      priority_bytes = Bytes[
        0x80, 0x00, 0x00, 0x00, # Exclusive, stream 0
        0xc8                    # Weight 200
      ]
      full_payload = headers_payload + priority_bytes

      # Send HEADERS frame with PRIORITY flag
      send_headers_frame(client_conn_socket, 1_u32, full_payload, end_stream: true, flags: HT2::FrameFlags::PRIORITY)
    end

    # Expect a normal response, no errors
    response = read_frames_until(client_mock_socket, HT2::HeadersFrame)
    response.should_not be_nil
    response.should be_a(HT2::HeadersFrame)

    # Ensure no RST_STREAM or GOAWAY frames were sent due to priority info
    error_frame = read_frame_with_timeout(client_mock_socket, timeout: 50.milliseconds)
    error_frame.should be_nil
  end
end

# Helper methods
private def run_test_scenario(&block : Proc(MockBidirectionalSocket, MockBidirectionalSocket, Nil))
  client_mock_socket = MockBidirectionalSocket.new
  server_mock_socket = MockBidirectionalSocket.new
  # Link the two mock sockets for bidirectional communication
  # Data written to client_mock_socket is read by server_mock_socket, and vice-versa
  spawn do
    loop do
      begin
        data = client_mock_socket.@write_channel.receive
        server_mock_socket.receive_data(data)
      rescue Channel::ClosedError
        break
      end
    end
  end
  spawn do
    loop do
      begin
        data = server_mock_socket.@write_channel.receive
        client_mock_socket.receive_data(data)
      rescue Channel::ClosedError
        break
      end
    end
  end
  server_connection = HT2::Connection.new(server_mock_socket, is_server: true)
  # Set up a simple handler that responds with 200 OK
  server_connection.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
    # Send a simple 200 OK response
    response_headers = [
      {":status", "200"},
      {"content-type", "text/plain"},
    ]
    stream.send_headers(response_headers, true)
  end
  # Start server connection processing in a fiber
  server_fiber = spawn { server_connection.start rescue nil }
  # Give server a moment to start and send initial SETTINGS
  sleep 50.milliseconds
  # Yield to the test block, passing the client-side mock socket
  yield client_mock_socket, server_mock_socket
  # Give server time to process frames and respond
  sleep 100.milliseconds
  {client_mock_socket, server_connection}
end

private def send_headers_frame(socket : MockBidirectionalSocket, stream_id : UInt32, payload : Bytes,
                               end_stream : Bool = false, end_headers : Bool = true, flags : HT2::FrameFlags? = nil)
  frame_flags = flags || HT2::FrameFlags::None
  frame_flags = frame_flags | HT2::FrameFlags::END_STREAM if end_stream
  frame_flags = frame_flags | HT2::FrameFlags::END_HEADERS if end_headers
  frame = HT2::HeadersFrame.new(stream_id, payload, frame_flags)
  frame.write_to(socket)
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

private def read_frame_with_timeout(socket : MockBidirectionalSocket, timeout : Time::Span = 100.milliseconds) : HT2::Frame?
  deadline = Time.monotonic + timeout
  while Time.monotonic < deadline
    begin
      # Attempt to read a frame
      header_bytes = Bytes.new(HT2::Frame::HEADER_SIZE)
      socket.read_fully(header_bytes)
      length, _, _, _ = HT2::Frame.parse_header(header_bytes)
      full_frame_bytes = Bytes.new(HT2::Frame::HEADER_SIZE + length)
      header_bytes.copy_to(full_frame_bytes)
      socket.read_fully(full_frame_bytes[HT2::Frame::HEADER_SIZE, length])
      parsed_frame = HT2::Frame.parse(full_frame_bytes[0, HT2::Frame::HEADER_SIZE + length])
      return parsed_frame
    rescue IO::EOFError | IO::TimeoutError
      # Expected if no data or timeout
      sleep 10.milliseconds
      next
    rescue ex
      # Other errors, log and continue trying or re-raise if critical
      sleep 10.milliseconds
      next
    end
  end
  nil
end

private def read_frames_until(socket : MockBidirectionalSocket, frame_type : HT2::Frame.class, timeout : Time::Span = 1.second) : HT2::Frame?
  deadline = Time.monotonic + timeout
  while Time.monotonic < deadline
    begin
      frame = read_frame_with_timeout(socket, timeout: deadline - Time.monotonic)
      return frame if frame && frame.class == frame_type
    rescue ex
      # Ignore errors during reading, might be incomplete frame
    end
    sleep 10.milliseconds
  end
  nil
end
