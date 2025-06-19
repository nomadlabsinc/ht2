require "../spec_helper"

describe "H2C Integration" do
  # Skip prior knowledge test for now - requires more complex buffering
  pending "accepts direct HTTP/2 connection with prior knowledge"

  it "handles HTTP/1.1 upgrade to h2c" do
    server = HT2::Server.new(
      host: "127.0.0.1",
      port: 0,
      handler: ->(request : HT2::Request, response : HT2::Response) {
        response.status = 200
        response.headers["content-type"] = "text/plain"
        response.write("Upgraded to H2C".to_slice)
        nil
      },
      enable_h2c: true
    )

    spawn { server.listen }
    sleep 0.1.seconds

    socket = TCPSocket.new("127.0.0.1", server.port)

    # Send HTTP/1.1 upgrade request
    request = String.build do |io|
      io << "GET / HTTP/1.1\r\n"
      io << "Host: localhost\r\n"
      io << "Connection: Upgrade\r\n"
      io << "Upgrade: h2c\r\n"
      io << "HTTP2-Settings: AAEAAA\r\n" # Empty settings
      io << "\r\n"
    end

    socket.write(request.to_slice)

    # Read 101 response
    response_lines = [] of String
    while line = socket.gets(limit: 1024)
      response_lines << line
      break if line.strip.empty?
    end

    response = response_lines.join("\n")
    response.should_not be_empty
    response.should contain("HTTP/1.1 101 Switching Protocols")
    response.should contain("Connection: Upgrade")
    response.should contain("Upgrade: h2c")

    # After upgrade, send HTTP/2 connection preface
    socket.write(HT2::CONNECTION_PREFACE.to_slice)

    # Send SETTINGS frame to complete upgrade
    settings_frame = HT2::SettingsFrame.new
    socket.write(settings_frame.to_bytes)

    # Should receive server's SETTINGS frame
    frame_header = Bytes.new(9)
    socket.read_fully(frame_header)

    frame_type = frame_header[3]
    frame_type.should eq(HT2::FrameType::SETTINGS.value)

    socket.close
    server.close
  end

  it "rejects non-h2c requests when h2c is enabled without TLS" do
    server = HT2::Server.new(
      host: "127.0.0.1",
      port: 0,
      handler: ->(request : HT2::Request, response : HT2::Response) {
        response.status = 200
        nil
      },
      enable_h2c: true
    )

    spawn { server.listen }
    sleep 0.1.seconds

    socket = TCPSocket.new("127.0.0.1", server.port)

    # Send regular HTTP/1.1 request (no upgrade)
    request = String.build do |io|
      io << "GET / HTTP/1.1\r\n"
      io << "Host: localhost\r\n"
      io << "Connection: close\r\n"
      io << "\r\n"
    end

    socket.write(request.to_slice)

    # Should receive 505 HTTP Version Not Supported
    response_data = Bytes.new(1024)
    bytes_read = socket.read(response_data) rescue 0
    response = String.new(response_data[0, bytes_read])
    response.should_not be_empty
    response.should start_with("HTTP/1.1 505 HTTP Version Not Supported")

    socket.close rescue nil
    server.close
  end

  it "handles h2c upgrade with custom settings" do
    server = HT2::Server.new(
      host: "127.0.0.1",
      port: 0,
      handler: ->(request : HT2::Request, response : HT2::Response) {
        response.status = 200
        response.write("OK".to_slice)
        nil
      },
      enable_h2c: true,
      h2c_upgrade_timeout: 5.seconds,
      header_table_size: 8192_u32,
      max_concurrent_streams: 200_u32
    )

    spawn { server.listen }
    sleep 0.1.seconds

    socket = TCPSocket.new("127.0.0.1", server.port)

    # Create settings with HEADER_TABLE_SIZE=4096
    settings_bytes = IO::Memory.new
    # HEADER_TABLE_SIZE (0x01) = 4096 (0x00001000)
    settings_bytes.write_bytes(0x0001_u16, IO::ByteFormat::BigEndian)
    settings_bytes.write_bytes(0x00001000_u32, IO::ByteFormat::BigEndian)

    encoded_settings = Base64.encode(settings_bytes.to_s).strip

    # Send HTTP/1.1 upgrade request
    request = String.build do |io|
      io << "GET /test HTTP/1.1\r\n"
      io << "Host: localhost:#{server.port}\r\n"
      io << "Connection: Upgrade\r\n"
      io << "Upgrade: h2c\r\n"
      io << "HTTP2-Settings: #{encoded_settings}\r\n"
      io << "\r\n"
    end

    socket.write(request.to_slice)

    # Read 101 response
    response_lines = [] of String
    while line = socket.gets(limit: 1024)
      response_lines << line
      break if line.strip.empty?
    end

    response = response_lines.join("\n")
    response.should_not be_empty
    response.should contain("HTTP/1.1 101 Switching Protocols")

    # After upgrade, send HTTP/2 connection preface
    socket.write(HT2::CONNECTION_PREFACE.to_slice)

    # Send SETTINGS frame
    settings_frame = HT2::SettingsFrame.new
    socket.write(settings_frame.to_bytes)

    # Should be able to receive server settings
    frame_header = Bytes.new(9)
    socket.read_fully(frame_header)

    socket.close
    server.close
  end

  it "handles h2c upgrade timeout" do
    server = HT2::Server.new(
      host: "127.0.0.1",
      port: 0,
      handler: ->(request : HT2::Request, response : HT2::Response) {
        response.status = 200
        nil
      },
      enable_h2c: true,
      h2c_upgrade_timeout: 0.1.seconds
    )

    spawn { server.listen }
    sleep 0.1.seconds

    socket = TCPSocket.new("127.0.0.1", server.port)

    # Start sending request but don't complete it
    socket.write("GET / HTTP/1.1\r\n".to_slice)

    # Wait for timeout
    sleep 0.2.seconds

    # Should receive 400 Bad Request due to timeout
    buffer = Bytes.new(200)
    bytes_read = socket.read(buffer) rescue 0
    bytes_read.should be > 0

    response = String.new(buffer[0, bytes_read])
    response.should contain("HTTP/1.1 400 Bad Request")

    socket.close rescue nil
    server.close
  end
end
