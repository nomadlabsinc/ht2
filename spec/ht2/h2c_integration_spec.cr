require "../spec_helper"

describe "H2C Integration" do
  it "accepts direct HTTP/2 connection with prior knowledge" do
    server = HT2::Server.new(
      host: "127.0.0.1",
      port: 0,
      handler: ->(request : HT2::Request, response : HT2::Response) {
        response.status = 200
        response.headers["content-type"] = "text/plain"
        response.write("Prior knowledge success".to_slice)
        nil
      },
      enable_h2c: true
    )

    server_fiber = spawn do
      server.listen
    rescue ex
      # Ignore errors when server is closed
    end

    # Ensure server is ready
    Fiber.yield
    sleep 0.05.seconds

    socket = TCPSocket.new("127.0.0.1", server.port)
    begin
      # Send HTTP/2 connection preface directly (prior knowledge)
      socket.write(HT2::CONNECTION_PREFACE.to_slice)

      # Send SETTINGS frame
      settings_frame = HT2::SettingsFrame.new
      socket.write(settings_frame.to_bytes)

      # Should receive server's SETTINGS frame
      frame_header = Bytes.new(9)
      socket.read_timeout = 1.second
      begin
        socket.read_fully(frame_header)
        frame_type = frame_header[3]
        frame_type.should eq(HT2::FrameType::SETTINGS.value)
      rescue IO::TimeoutError
        raise "Timeout waiting for server SETTINGS frame"
      end

      # Receive and ACK the SETTINGS
      payload_length = (frame_header[0].to_u32 << 16) | (frame_header[1].to_u32 << 8) | frame_header[2].to_u32
      payload = Bytes.new(payload_length.to_i)
      socket.read_fully(payload) if payload_length > 0

      # Send SETTINGS ACK
      settings_ack = HT2::SettingsFrame.new(flags: HT2::FrameFlags::ACK)
      socket.write(settings_ack.to_bytes)

      # Wait a bit for server to process
      sleep 0.05.seconds

      # Now send a request
      headers = [
        {":method", "GET"},
        {":path", "/test"},
        {":scheme", "http"},
        {":authority", "127.0.0.1:#{server.port}"},
      ]

      # Use a simple encoder for testing
      encoder = HT2::HPACK::Encoder.new
      header_block = encoder.encode(headers)

      headers_frame = HT2::HeadersFrame.new(
        stream_id: 1_u32,
        header_block: header_block,
        flags: HT2::FrameFlags::END_HEADERS | HT2::FrameFlags::END_STREAM
      )
      socket.write(headers_frame.to_bytes)

      # Read frames until we get HEADERS frame for our request
      received_headers = false
      10.times do
        response_header = Bytes.new(9)
        socket.read_timeout = 1.second
        begin
          socket.read_fully(response_header)
        rescue IO::TimeoutError
          break
        end

        frame_type = response_header[3]
        stream_id = ((response_header[5].to_u32 << 24) | (response_header[6].to_u32 << 16) |
                     (response_header[7].to_u32 << 8) | response_header[8]) & 0x7FFFFFFF
        payload_length = (response_header[0].to_u32 << 16) | (response_header[1].to_u32 << 8) | response_header[2].to_u32

        # Read payload if present
        if payload_length > 0
          payload = Bytes.new(payload_length.to_i)
          socket.read_fully(payload)
        end

        # ACK any SETTINGS frames
        if frame_type == HT2::FrameType::SETTINGS.value && stream_id == 0
          flags = response_header[4]
          if (flags & HT2::FrameFlags::ACK.value) == 0
            ack = HT2::SettingsFrame.new(flags: HT2::FrameFlags::ACK)
            socket.write(ack.to_bytes)
            socket.flush
          end
        end

        # Check if we got HEADERS for stream 1
        if frame_type == HT2::FrameType::HEADERS.value && stream_id == 1
          received_headers = true
          break
        end
      end

      received_headers.should be_true
    ensure
      socket.close rescue nil
      server.close
      # Wait for server fiber and any connection fibers to finish
      sleep 0.1.seconds
    end
  end

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

    server_fiber = spawn do
      server.listen
    rescue ex
      # Ignore errors when server is closed
    end

    # Ensure server is ready
    Fiber.yield
    sleep 0.05.seconds

    socket = TCPSocket.new("127.0.0.1", server.port)
    begin
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
      socket.read_timeout = 1.second
      begin
        socket.read_fully(frame_header)
        frame_type = frame_header[3]
        frame_type.should eq(HT2::FrameType::SETTINGS.value)
      rescue IO::TimeoutError
        raise "Timeout waiting for server SETTINGS frame"
      end
    ensure
      socket.close rescue nil
      server.close
      # Wait for server fiber and any connection fibers to finish
      sleep 0.1.seconds
    end
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

    server_fiber = spawn do
      server.listen
    rescue ex
      # Ignore errors when server is closed
    end

    # Ensure server is ready
    Fiber.yield
    sleep 0.05.seconds

    socket = TCPSocket.new("127.0.0.1", server.port)
    begin
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
    ensure
      socket.close rescue nil
      server.close
      # Wait for server fiber and any connection fibers to finish
      sleep 0.1.seconds
    end
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
      h2c_upgrade_timeout: 1.second,
      header_table_size: 8192_u32,
      max_concurrent_streams: 200_u32
    )

    server_fiber = spawn do
      server.listen
    rescue ex
      # Ignore errors when server is closed
    end

    # Ensure server is ready
    Fiber.yield
    sleep 0.05.seconds

    socket = TCPSocket.new("127.0.0.1", server.port)
    begin
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
      socket.read_timeout = 1.second
      begin
        socket.read_fully(frame_header)
      rescue IO::TimeoutError
        raise "Timeout waiting for server SETTINGS frame"
      end
    ensure
      socket.close rescue nil
      server.close
      # Wait for server fiber and any connection fibers to finish
      sleep 0.1.seconds
    end
  end

  it "handles invalid HTTP version for h2c" do
    server = HT2::Server.new(
      host: "127.0.0.1",
      port: 0,
      handler: ->(request : HT2::Request, response : HT2::Response) {
        response.status = 200
        nil
      },
      enable_h2c: true
    )

    server_fiber = spawn do
      server.listen
    rescue ex
      # Ignore errors when server is closed
    end

    # Ensure server is ready
    Fiber.yield
    sleep 0.05.seconds

    socket = TCPSocket.new("127.0.0.1", server.port)
    begin
      # Send HTTP/1.0 request (server expects HTTP/1.1 for h2c)
      request = String.build do |io|
        io << "GET / HTTP/1.0\r\n"
        io << "Host: localhost\r\n"
        io << "\r\n"
      end

      socket.write(request.to_slice)
      socket.flush

      # Should receive 400 Bad Request
      buffer = Bytes.new(200)
      bytes_read = socket.read(buffer)
      bytes_read.should be > 0

      response = String.new(buffer[0, bytes_read])
      response.should contain("HTTP/1.1 400 Bad Request")
    ensure
      socket.close rescue nil
      server.close
      # Wait for server fiber and any connection fibers to finish
      sleep 0.1.seconds
    end
  end
end
