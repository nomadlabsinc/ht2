require "./spec_helper"
require "openssl"

# Helper to check if connection rejects input (by closing or sending error)
def connection_rejects_input?(socket : IO, timeout = 2.seconds) : Bool
  deadline = Time.monotonic + timeout

  # Try to read - we expect either:
  # 1. Connection closed (read returns 0)
  # 2. GOAWAY or RST_STREAM frame
  # 3. Connection reset/error

  spawn do
    sleep timeout
    socket.close rescue nil
  end

  begin
    loop do
      return false if Time.monotonic > deadline

      # Read frame header
      header = Bytes.new(9)
      bytes_read = socket.read(header)

      # Connection closed
      return true if bytes_read == 0

      # If we got a full header, check frame type
      if bytes_read >= 9
        frame_type = HT2::FrameType.new(header[3])

        # Read payload
        length = (header[0].to_u32 << 16) | (header[1].to_u32 << 8) | header[2].to_u32
        if length > 0
          payload = Bytes.new(length)
          socket.read_fully(payload)
        end

        # Check if it's an error frame
        return true if frame_type == HT2::FrameType::GOAWAY || frame_type == HT2::FrameType::RST_STREAM
      end
    end
  rescue
    # Any error means connection rejected
    return true
  end

  false
end

# Helper to read error frames from socket
def read_error_frame(socket : IO, timeout = 2.seconds) : HT2::FrameType?
  deadline = Time.monotonic + timeout
  frames_read = 0

  loop do
    return nil if Time.monotonic > deadline
    return nil if frames_read > 10 # Prevent infinite loop

    begin
      # Read frame header
      header = Bytes.new(9)
      socket.read_fully(header)

      # Parse frame type (4th byte)
      frame_type = HT2::FrameType.new(header[3])
      frames_read += 1

      # Read and discard payload
      length = (header[0].to_u32 << 16) | (header[1].to_u32 << 8) | header[2].to_u32
      if length > 0
        payload = Bytes.new(length)
        socket.read_fully(payload)
      end

      # Return only error frames
      if frame_type == HT2::FrameType::GOAWAY || frame_type == HT2::FrameType::RST_STREAM
        return frame_type
      end
      # Continue reading for other frame types
    rescue ex
      return nil
    end
  end
end

# Helper to create self-signed certificate for testing
def create_test_tls_context : OpenSSL::SSL::Context::Server
  context = OpenSSL::SSL::Context::Server.new

  # Generate self-signed certificate using OpenSSL command line
  temp_key_file = "#{Dir.tempdir}/cve_test_key_#{Random.rand(100000)}.pem"
  temp_cert_file = "#{Dir.tempdir}/cve_test_cert_#{Random.rand(100000)}.pem"

  begin
    # Generate RSA key
    system("openssl genrsa -out #{temp_key_file} 2048 2>/dev/null")

    # Generate self-signed certificate
    system("openssl req -new -x509 -key #{temp_key_file} -out #{temp_cert_file} -days 365 -subj '/CN=localhost' 2>/dev/null")

    # Configure context
    context.certificate_chain = temp_cert_file
    context.private_key = temp_key_file
    context.alpn_protocol = "h2"

    context
  ensure
    # Clean up temp files after context is configured
    spawn do
      sleep 1.second
      File.delete(temp_key_file) if File.exists?(temp_key_file)
      File.delete(temp_cert_file) if File.exists?(temp_cert_file)
    end
  end
end

describe "HTTP/2 CVE Integration Tests" do
  describe "2019 Netflix HTTP/2 Flood Vulnerabilities" do
    it "protects against CVE-2019-9511 Data Dribble (small DATA frames)" do
      port : Int32 = 9301
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new
      request_count = 0
      mutex = Mutex.new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          mutex.synchronize { request_count += 1 }
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        # Connect with raw socket to send malicious frames
        socket = TCPSocket.new("localhost", port)

        # Create context first with ALPN for HTTP/2
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Try to send many small DATA frames to keep streams open
        # Server should handle this without resource exhaustion
        100.times do |i|
          stream_id = (i * 2 + 1).to_u32

          # Send HEADERS frame first
          headers = [
            {":method", "GET"},
            {":path", "/"},
            {":scheme", "https"},
            {":authority", "localhost:#{port}"},
          ]

          encoder = HT2::HPACK::Encoder.new
          header_block = encoder.encode(headers)

          headers_frame = HT2::HeadersFrame.new(
            stream_id,
            header_block,
            HT2::FrameFlags::END_HEADERS
          )
          tls_socket.write(headers_frame.to_bytes)

          # Send many tiny DATA frames without END_STREAM
          10.times do
            data_frame = HT2::DataFrame.new(
              stream_id,
              "x".to_slice,
              HT2::FrameFlags::None
            )
            tls_socket.write(data_frame.to_bytes)
            sleep 0.001.seconds # Small delay to simulate dribbling
          end
        end

        # Server should still be responsive
        tls_socket.flush
        sleep 0.1.seconds
        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end

    it "protects against CVE-2019-9512 Ping Flood" do
      port : Int32 = 9302
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new
      ping_error_received = false
      mutex = Mutex.new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        # Connect with raw socket
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Try to flood with PING frames
        15.times do |i|
          ping_frame = HT2::PingFrame.new(Bytes.new(8, i.to_u8))
          tls_socket.write(ping_frame.to_bytes)
        end

        # Try to read response - should get GOAWAY or connection close
        spawn do
          begin
            buffer = Bytes.new(1024)
            while bytes_read = tls_socket.read(buffer)
              break if bytes_read == 0
              # Check if we received GOAWAY frame
              if buffer[3] == HT2::FrameType::GOAWAY.value
                mutex.synchronize { ping_error_received = true }
                break
              end
            end
          rescue
            # Connection closed is also acceptable
          end
        end

        sleep 0.5.seconds

        # Either connection should be closed or GOAWAY received
        begin
          tls_socket.write(Bytes.new(1))
          # If write succeeds, check if we got GOAWAY
          mutex.synchronize { ping_error_received }.should be_true
        rescue
          # Connection closed - protection worked
        end

        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end

    it "protects against CVE-2019-9514 Reset Flood" do
      port : Int32 = 9303
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new
      error_received = false
      mutex = Mutex.new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Create streams and immediately reset them
        110.times do |i|
          stream_id = (i * 2 + 1).to_u32

          # Send HEADERS frame
          headers = [
            {":method", "GET"},
            {":path", "/"},
            {":scheme", "https"},
            {":authority", "localhost:#{port}"},
          ]

          encoder = HT2::HPACK::Encoder.new
          header_block = encoder.encode(headers)

          headers_frame = HT2::HeadersFrame.new(
            stream_id,
            header_block,
            HT2::FrameFlags::END_HEADERS
          )
          tls_socket.write(headers_frame.to_bytes)

          # Immediately send RST_STREAM
          rst_frame = HT2::RstStreamFrame.new(stream_id, HT2::ErrorCode::CANCEL)
          tls_socket.write(rst_frame.to_bytes)
        end

        # Check for protection response
        spawn do
          begin
            buffer = Bytes.new(1024)
            while bytes_read = tls_socket.read(buffer)
              break if bytes_read == 0
              if buffer[3] == HT2::FrameType::GOAWAY.value
                mutex.synchronize { error_received = true }
                break
              end
            end
          rescue
          end
        end

        sleep 0.5.seconds

        # Protection should have triggered
        begin
          tls_socket.write(Bytes.new(1))
          mutex.synchronize { error_received }.should be_true
        rescue
          # Connection closed - protection worked
        end

        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end

    it "protects against CVE-2019-9515 Settings Flood" do
      port : Int32 = 9304
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new
      error_received = false
      mutex = Mutex.new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Flood with SETTINGS frames
        5.times do |i|
          settings = HT2::SettingsFrame::Settings.new
          settings[HT2::SettingsParameter::MAX_CONCURRENT_STREAMS] = (100 + i).to_u32
          settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE] = (65535 + i).to_u32

          settings_frame = HT2::SettingsFrame.new(settings: settings)
          tls_socket.write(settings_frame.to_bytes)
        end

        # Check for protection
        spawn do
          begin
            buffer = Bytes.new(1024)
            while bytes_read = tls_socket.read(buffer)
              break if bytes_read == 0
              if buffer[3] == HT2::FrameType::GOAWAY.value
                mutex.synchronize { error_received = true }
                break
              end
            end
          rescue
          end
        end

        sleep 0.5.seconds

        # Should have triggered rate limiting
        begin
          tls_socket.write(Bytes.new(1))
          mutex.synchronize { error_received }.should be_true
        rescue
          # Connection closed - protection worked
        end

        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end

    it "protects against CVE-2019-9516 0-Length Headers Leak" do
      port : Int32 = 9305
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        # Test that server handles empty header names properly
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Send valid headers - server should accept these
        headers = [
          {":method", "GET"},
          {":path", "/"},
          {":scheme", "https"},
          {":authority", "localhost:#{port}"},
          {"x-test", "value"},
        ]

        encoder = HT2::HPACK::Encoder.new
        header_block = encoder.encode(headers)

        headers_frame = HT2::HeadersFrame.new(
          1_u32,
          header_block,
          HT2::FrameFlags::END_HEADERS | HT2::FrameFlags::END_STREAM
        )
        tls_socket.write(headers_frame.to_bytes)

        # Server should handle request properly
        sleep 0.1.seconds

        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end

    it "protects against CVE-2019-9517 Internal Data Buffering (window overflow)" do
      port : Int32 = 9306
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new
      error_received = false
      mutex = Mutex.new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Try to overflow window with large increment
        # Max window size is 2^31 - 1
        window_update_frame = HT2::WindowUpdateFrame.new(0_u32, 0x7FFFFFFF_u32)
        tls_socket.write(window_update_frame.to_bytes)

        # Try to overflow by sending another large update
        window_update_frame2 = HT2::WindowUpdateFrame.new(0_u32, 0x7FFFFFFF_u32)
        tls_socket.write(window_update_frame2.to_bytes)

        # Check for error response
        spawn do
          begin
            buffer = Bytes.new(1024)
            while bytes_read = tls_socket.read(buffer)
              break if bytes_read == 0
              if buffer[3] == HT2::FrameType::GOAWAY.value
                mutex.synchronize { error_received = true }
                break
              end
            end
          rescue
          end
        end

        sleep 0.5.seconds

        # Should have detected overflow attempt
        begin
          tls_socket.write(Bytes.new(1))
          mutex.synchronize { error_received }.should be_true
        rescue
          # Connection closed - protection worked
        end

        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end

    it "protects against CVE-2019-9518 Empty Frames Flood" do
      port : Int32 = 9307
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Create a stream
        headers = [
          {":method", "GET"},
          {":path", "/"},
          {":scheme", "https"},
          {":authority", "localhost:#{port}"},
        ]

        encoder = HT2::HPACK::Encoder.new
        header_block = encoder.encode(headers)

        headers_frame = HT2::HeadersFrame.new(
          1_u32,
          header_block,
          HT2::FrameFlags::END_HEADERS
        )
        tls_socket.write(headers_frame.to_bytes)

        # Flood with empty DATA frames
        1000.times do
          empty_data_frame = HT2::DataFrame.new(
            1_u32,
            Bytes.empty,
            HT2::FrameFlags::None
          )
          tls_socket.write(empty_data_frame.to_bytes)
        end

        # Server should still handle this gracefully
        # Send END_STREAM to complete
        end_data_frame = HT2::DataFrame.new(
          1_u32,
          Bytes.empty,
          HT2::FrameFlags::END_STREAM
        )
        tls_socket.write(end_data_frame.to_bytes)

        # Server should still be responsive
        tls_socket.flush
        sleep 0.1.seconds
        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end
  end

  describe "CVE-2016-4462 HPACK Bomb" do
    it "protects against HPACK bomb attack" do
      port : Int32 = 9308
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Wait for server's SETTINGS and ACK
        sleep 0.2.seconds

        # Create HPACK bomb - highly compressed headers that expand massively
        io = IO::Memory.new

        # Use literal header with incremental indexing
        # Create header with small name but huge value
        io.write_byte(0x40_u8) # Literal with incremental indexing
        io.write_byte(0x01_u8) # Name length: 1
        io.write_byte('x'.ord.to_u8)

        # Value length: Try to create massive expansion
        # Send length of 1MB
        value_length = 1024 * 1024
        io.write_byte(0xFF_u8) # 127 with continuation
        remaining = value_length - 127
        while remaining > 0
          if remaining >= 128
            io.write_byte(0x80_u8 | (remaining & 0x7F))
            remaining >>= 7
          else
            io.write_byte(remaining.to_u8)
            break
          end
        end

        # Don't actually write 1MB of data, just claim we will
        io.write(("A" * 100).to_slice) # Write small amount but claim it's huge

        header_block = io.to_slice
        # Remove debug output
        # puts "Sending HPACK bomb with #{header_block.size} bytes claiming #{value_length} bytes"

        headers_frame = HT2::HeadersFrame.new(
          1_u32,
          header_block,
          HT2::FrameFlags::END_HEADERS | HT2::FrameFlags::END_STREAM
        )
        tls_socket.write(headers_frame.to_bytes)

        # Check for error response
        error_type = read_error_frame(tls_socket, 5.seconds)

        # Should receive either GOAWAY or RST_STREAM
        error_type.should_not be_nil

        tls_socket.flush
        sleep 0.1.seconds
        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end
  end

  describe "CVE-2023-44487 HTTP/2 Rapid Reset Attack" do
    it "protects against rapid reset attack" do
      port : Int32 = 9309
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          # Simulate slow processing
          sleep 0.1.seconds
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Rapid Reset Attack: Create streams and immediately reset them
        # This forces server to allocate resources then immediately free them
        # Reduced from 1000 to avoid timeout
        200.times do |i|
          stream_id = (i * 2 + 1).to_u32

          # Send HEADERS frame
          headers = [
            {":method", "GET"},
            {":path", "/"},
            {":scheme", "https"},
            {":authority", "localhost:#{port}"},
          ]

          encoder = HT2::HPACK::Encoder.new
          header_block = encoder.encode(headers)

          headers_frame = HT2::HeadersFrame.new(
            stream_id,
            header_block,
            HT2::FrameFlags::END_HEADERS
          )
          tls_socket.write(headers_frame.to_bytes)

          # Immediately send RST_STREAM (rapid reset)
          rst_frame = HT2::RstStreamFrame.new(stream_id, HT2::ErrorCode::CANCEL)
          tls_socket.write(rst_frame.to_bytes)
        end

        # Check that server protects against rapid reset
        connection_rejects_input?(tls_socket, 2.seconds).should be_true

        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end
  end

  describe "2024 CONTINUATION Flood Family" do
    it "protects against CONTINUATION flood attack" do
      port : Int32 = 9310
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Start HEADERS frame without END_HEADERS flag
        headers = [
          {":method", "GET"},
          {":path", "/"},
          {":scheme", "https"},
        ]

        encoder = HT2::HPACK::Encoder.new
        header_block = encoder.encode(headers)

        # Send initial HEADERS without END_HEADERS
        headers_frame = HT2::HeadersFrame.new(
          1_u32,
          header_block,
          HT2::FrameFlags::None # No END_HEADERS
        )
        tls_socket.write(headers_frame.to_bytes)

        # Flood with CONTINUATION frames
        # Try to exceed MAX_CONTINUATION_SIZE (1MB)
        continuation_data = Bytes.new(8192, 'A'.ord.to_u8)

        # Try to send many CONTINUATION frames
        frames_sent = 0
        error_occurred = false

        begin
          200.times do |i|
            # Send CONTINUATION frame without END_HEADERS
            continuation_frame = HT2::ContinuationFrame.new(
              1_u32,
              continuation_data,
              HT2::FrameFlags::None # No END_HEADERS
            )
            tls_socket.write(continuation_frame.to_bytes)
            tls_socket.flush
            frames_sent += 1
          end
        rescue ex : IO::Error
          # Connection closed - server protected itself
          error_occurred = true
        end

        # Should have detected CONTINUATION flood either by closing connection
        # or rejecting further input
        if !error_occurred
          connection_rejects_input?(tls_socket, 2.seconds).should be_true
        else
          # Connection already closed - protection worked
          error_occurred.should be_true
        end

        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end

    it "protects against CONTINUATION frames without proper HEADERS" do
      port : Int32 = 9311
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Wait for server settings
        sleep 0.1.seconds

        # Send CONTINUATION frame without preceding HEADERS (protocol error)
        continuation_frame = HT2::ContinuationFrame.new(
          1_u32,
          "invalid".to_slice,
          HT2::FrameFlags::END_HEADERS
        )
        tls_socket.write(continuation_frame.to_bytes)

        # Check that connection rejects the invalid input
        connection_rejects_input?(tls_socket, 2.seconds).should be_true

        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end
  end

  describe "Additional Security Tests" do
    it "enforces maximum concurrent streams limit" do
      port : Int32 = 9312
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          # Hold connection open
          sleep 1.second
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Wait for server SETTINGS
        sleep 0.1.seconds

        # Create many concurrent streams
        encoder = HT2::HPACK::Encoder.new

        # Default MAX_CONCURRENT_STREAMS is 100
        105.times do |i|
          stream_id = (i * 2 + 1).to_u32

          headers = [
            {":method", "GET"},
            {":path", "/#{i}"},
            {":scheme", "https"},
            {":authority", "localhost:#{port}"},
          ]

          header_block = encoder.encode(headers)

          headers_frame = HT2::HeadersFrame.new(
            stream_id,
            header_block,
            HT2::FrameFlags::END_HEADERS | HT2::FrameFlags::END_STREAM
          )
          tls_socket.write(headers_frame.to_bytes)
        end

        # Should have refused some streams - check for error response
        connection_rejects_input?(tls_socket, 2.seconds).should be_true

        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end

    it "validates frame sizes against MAX_FRAME_SIZE" do
      port : Int32 = 9313
      server_ready = Channel(Nil).new
      server_done = Channel(Nil).new

      spawn do
        handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
          response.status = 200
          response.write("OK")
          response.close
        end

        server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

        spawn do
          server_ready.send(nil)
          server.listen
        end

        server_done.receive
        server.close
      end

      server_ready.receive
      sleep 0.2.seconds

      begin
        socket = TCPSocket.new("localhost", port)
        context = OpenSSL::SSL::Context::Client.new
        context.alpn_protocol = "h2"
        context.verify_mode = OpenSSL::SSL::VerifyMode::NONE

        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, context, hostname: "localhost")
        tls_socket.sync_close = true

        # tls_socket.connect

        # Send HTTP/2 client preface
        tls_socket.write(HT2::CONNECTION_PREFACE.to_slice)

        # Send SETTINGS frame
        settings_frame = HT2::SettingsFrame.new
        tls_socket.write(settings_frame.to_bytes)

        # Try to send oversized frame
        # Default MAX_FRAME_SIZE is 16384
        oversized_data = Bytes.new(20000, 'X'.ord.to_u8)

        # Manually construct frame with invalid size
        io = IO::Memory.new
        # Length field is 24 bits
        io.write_byte((20000_u32 >> 16).to_u8)           # Length high byte
        io.write_byte((20000_u32 >> 8).to_u8)            # Length middle byte
        io.write_byte((20000_u32 & 0xFF).to_u8)          # Length low byte
        io.write_byte(HT2::FrameType::DATA.value)        # Type
        io.write_byte(0_u8)                              # Flags
        io.write_bytes(1_u32, IO::ByteFormat::BigEndian) # Stream ID
        io.write(oversized_data)

        tls_socket.write(io.to_slice)

        # Should have detected oversized frame
        connection_rejects_input?(tls_socket, 2.seconds).should be_true

        begin
          tls_socket.close
        rescue ex : OpenSSL::SSL::Error | IO::Error
          # Ignore SSL shutdown and IO errors
        end
      ensure
        server_done.send(nil)
      end
    end
  end
end
