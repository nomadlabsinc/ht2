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

    # Start both connections
    spawn { server_conn.start }
    spawn { client_conn.start }

    # Wait for handshake
    sleep 0.1.seconds

    # Create a stream
    stream = client_conn.create_stream
    stream.send_headers([{"content-type", "text/plain"}])

    data_received = [] of String
    end_stream_received = false

    # Server handles data
    server_conn.on_data = ->(s : HT2::Stream, data : Bytes, end_stream : Bool) do
      data_received << String.new(data)
      end_stream_received = end_stream
    end

    # Send multiple data chunks
    chunks = [
      "First chunk".to_slice,
      "Second chunk".to_slice,
      "Third chunk".to_slice,
    ]

    client_conn.send_data_frames(stream.id, chunks, end_stream: true)

    # Wait for data
    sleep 0.2.seconds

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

    # Start connections
    spawn { server_conn.start }
    spawn { client_conn.start }

    # Wait for initial handshake
    sleep 0.1.seconds

    headers_received = [] of Array(Tuple(String, String))

    server_conn.on_headers = ->(s : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
      headers_received << headers
    end

    # Create multiple streams with headers
    5.times do |i|
      stream = client_conn.create_stream
      headers = [
        {"content-type", "text/plain"},
        {"x-stream-id", i.to_s},
        {"x-custom-header", "value-#{i}"},
      ]
      stream.send_headers(headers, end_stream: true)
    end

    # Wait for headers
    sleep 0.2.seconds

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
