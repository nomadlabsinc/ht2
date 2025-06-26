require "../spec_helper"

describe "Multi-frame writer integration" do
  it "sends multiple frames efficiently over a connection" do
    server_socket, client_socket = create_socket_pair

    server_conn = HT2::Connection.new(server_socket, is_server: true)
    client_conn = HT2::Connection.new(client_socket, is_server: false)

    frames_received = [] of HT2::Frame

    # Server reads frames
    spawn do
      begin
        loop do
          header = Bytes.new(HT2::Frame::HEADER_SIZE)
          server_socket.read_fully(header)

          length, type, flags, stream_id = HT2::Frame.parse_header(header)

          full_frame = Bytes.new(HT2::Frame::HEADER_SIZE + length)
          header.copy_to(full_frame)

          if length > 0
            server_socket.read_fully(full_frame[HT2::Frame::HEADER_SIZE, length])
          end

          frame = HT2::Frame.parse(full_frame)
          frames_received << frame

          # Stop after receiving GOAWAY
          break if frame.is_a?(HT2::GoAwayFrame)
        end
      rescue IO::Error
        # Expected when connection closes
      end
    end

    # Client sends multiple frames
    frames_to_send = [
      HT2::WindowUpdateFrame.new(0_u32, 65535_u32),
      HT2::PingFrame.new(Bytes.new(8, 42)),
      HT2::SettingsFrame.new(HT2::FrameFlags::ACK),
      HT2::GoAwayFrame.new(0_u32, HT2::ErrorCode::NO_ERROR),
    ]

    client_conn.send_frames(frames_to_send)

    # Wait for frames to be received
    sleep 0.1.seconds

    frames_received.size.should eq(4)
    frames_received[0].should be_a(HT2::WindowUpdateFrame)
    frames_received[1].should be_a(HT2::PingFrame)
    frames_received[2].should be_a(HT2::SettingsFrame)
    frames_received[3].should be_a(HT2::GoAwayFrame)
  ensure
    server_socket.try(&.close) rescue nil
    client_socket.try(&.close) rescue nil
  end

  it "sends prioritized frames in correct order" do
    server_socket, client_socket = create_socket_pair

    server_conn = HT2::Connection.new(server_socket, is_server: true)
    client_conn = HT2::Connection.new(client_socket, is_server: false)

    frames_received = [] of HT2::FrameType

    # Server reads frame types
    spawn do
      3.times do
        header = Bytes.new(HT2::Frame::HEADER_SIZE)
        server_socket.read_fully(header)

        length, type, _, _ = HT2::Frame.parse_header(header)
        frames_received << type

        # Skip payload
        server_socket.skip(length) if length > 0
      end
    rescue IO::Error
    end

    # Client sends prioritized frames
    prioritized = [
      HT2::MultiFrameWriter::PrioritizedFrame.new(
        HT2::PingFrame.new(Bytes.new(8, 1)),
        priority: 5
      ),
      HT2::MultiFrameWriter::PrioritizedFrame.new(
        HT2::SettingsFrame.new(HT2::FrameFlags::ACK),
        priority: 10 # Highest priority
      ),
      HT2::MultiFrameWriter::PrioritizedFrame.new(
        HT2::WindowUpdateFrame.new(0_u32, 1000_u32),
        priority: 1 # Lowest priority
      ),
    ]

    client_conn.send_prioritized_frames(prioritized)

    # Wait for frames
    sleep 0.1.seconds

    # Should receive in priority order: SETTINGS, PING, WINDOW_UPDATE
    frames_received.size.should eq(3)
    frames_received[0].should eq(HT2::FrameType::SETTINGS)
    frames_received[1].should eq(HT2::FrameType::PING)
    frames_received[2].should eq(HT2::FrameType::WINDOW_UPDATE)
  ensure
    server_socket.try(&.close) rescue nil
    client_socket.try(&.close) rescue nil
  end

  it "handles DATA frame batching correctly" do
    server_socket, client_socket = create_socket_pair

    server_conn = HT2::Connection.new(server_socket, is_server: true)
    client_conn = HT2::Connection.new(client_socket, is_server: false)

    data_received = [] of String
    end_stream_received = false
    headers_received = false

    # Server handles headers and data - set callbacks BEFORE starting
    server_conn.on_headers = ->(s : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
      headers_received = true
      # Important: don't close the stream yet by sending response
    end

    server_conn.on_data = ->(s : HT2::Stream, data : Bytes, end_stream : Bool) do
      data_received << String.new(data)
      end_stream_received = end_stream

      # Send response after all data is received
      if end_stream
        response_headers = [
          {":status", "200"},
          {"content-type", "text/plain"},
        ]
        s.send_headers(response_headers, true)
      end
    end

    # Start both connections
    spawn { server_conn.start }
    spawn { client_conn.start }

    # Wait for handshake to complete
    sleep 0.2.seconds

    # Create a stream
    stream = client_conn.create_stream

    # Send headers without ending the stream
    stream.send_headers([
      {":method", "POST"},
      {":scheme", "https"},
      {":path", "/"},
      {":authority", "localhost"},
      {"content-type", "text/plain"},
    ], end_stream: false)

    # Give headers time to be processed
    sleep 0.1.seconds

    # Verify headers were received before sending data
    headers_received.should be_true

    # Send multiple data chunks
    chunks = [
      "First chunk".to_slice,
      "Second chunk".to_slice,
      "Third chunk".to_slice,
    ]

    # Send data through the stream
    chunks.each_with_index do |chunk, i|
      is_last = (i == chunks.size - 1)
      stream.send_data(chunk, end_stream: is_last)
      sleep 0.01.seconds # Small delay between chunks
    end

    # Wait for data to be processed
    sleep 0.3.seconds

    data_received.size.should eq(3)
    data_received.should eq(["First chunk", "Second chunk", "Third chunk"])
    end_stream_received.should be_true
  ensure
    server_socket.try(&.close) rescue nil
    client_socket.try(&.close) rescue nil
  end

  it "handles multiple header frames efficiently" do
    server_socket, client_socket = create_socket_pair

    server_conn = HT2::Connection.new(server_socket, is_server: true)
    client_conn = HT2::Connection.new(client_socket, is_server: false)

    headers_received = [] of Array(Tuple(String, String))

    # Set callback BEFORE starting
    server_conn.on_headers = ->(s : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
      headers_received << headers
    end

    # Start connections
    spawn { server_conn.start }
    spawn { client_conn.start }

    # Wait for initial handshake to complete
    sleep 0.2.seconds

    # Create multiple streams with headers
    5.times do |i|
      stream = client_conn.create_stream
      headers = [
        {":method", "GET"},
        {":scheme", "https"},
        {":path", "/test-#{i}"},
        {":authority", "localhost"},
        {"content-type", "text/plain"},
        {"x-stream-id", i.to_s},
        {"x-custom-header", "value-#{i}"},
      ]
      stream.send_headers(headers, end_stream: true)
    end

    # Wait for headers to be processed
    sleep 0.3.seconds

    headers_received.size.should eq(5)
    headers_received.each_with_index do |headers, i|
      headers.should contain({"x-stream-id", i.to_s})
    end
  ensure
    server_socket.try(&.close) rescue nil
    client_socket.try(&.close) rescue nil
  end
end

# Helper to create connected socket pair
private def create_socket_pair : Tuple(IO, IO)
  server = TCPServer.new("localhost", 0)
  port = server.local_address.port

  client = TCPSocket.new("localhost", port)
  server_client = server.accept
  server.close

  {server_client, client}
end
