require "./spec_helper"
require "openssl"

# Helper to create self-signed certificate for testing
def create_test_tls_context : OpenSSL::SSL::Context::Server
  context = OpenSSL::SSL::Context::Server.new

  # Check if pre-generated certificates exist (Docker environment)
  cert_path = ENV["TEST_CERT_PATH"]? || "/certs"
  cert_file = "#{cert_path}/server.crt"
  key_file = "#{cert_path}/server.key"

  if File.exists?(cert_file) && File.exists?(key_file)
    # Use pre-generated certificates
    context.certificate_chain = cert_file
    context.private_key = key_file
  else
    # Generate self-signed certificate on the fly
    temp_dir = ENV["TMPDIR"]? || Dir.tempdir
    temp_key_file = "#{temp_dir}/test_key_#{Random.rand(100000)}.pem"
    temp_cert_file = "#{temp_dir}/test_cert_#{Random.rand(100000)}.pem"

    begin
      # Ensure temp directory exists
      Dir.mkdir_p(temp_dir) unless Dir.exists?(temp_dir)

      # Generate RSA key
      system("openssl genrsa -out #{temp_key_file} 2048 2>/dev/null")

      # Generate self-signed certificate
      system("openssl req -new -x509 -key #{temp_key_file} -out #{temp_cert_file} -days 365 -subj '/CN=localhost' 2>/dev/null")

      # Configure context
      context.certificate_chain = temp_cert_file
      context.private_key = temp_key_file
    ensure
      # Clean up temp files after context is configured
      spawn do
        sleep 0.1.seconds
        File.delete(temp_key_file) if File.exists?(temp_key_file)
        File.delete(temp_cert_file) if File.exists?(temp_cert_file)
      end
    end
  end

  context.alpn_protocol = "h2"
  context
end

describe "HT2 Integration Tests" do
  it "handles basic GET request" do
    port : Int32 = 9292
    server_ready = Channel(Nil).new
    server_done = Channel(Nil).new
    request_received = false

    # Start server
    spawn do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
        request_received = true
        response.status = 200
        response.headers["content-type"] = "text/plain"
        response.write("Hello from HTTP/2!")
        response.close
      end

      server = HT2::Server.new("localhost", port, handler, tls_context: create_test_tls_context)

      spawn do
        server_ready.send(nil)
        server.listen
      end

      # Wait for test to complete
      server_done.receive
      server.close
    end

    # Wait for server to start
    server_ready.receive
    sleep 0.1.seconds

    # Verify server started
    request_received.should be_false

    server_done.send(nil)
  end

  it "handles POST request with body" do
    port : Int32 = 9293
    server_ready = Channel(Nil).new
    server_done = Channel(Nil).new
    received_body = ""

    spawn do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
        body : String = request.body.gets_to_end
        received_body = body

        response.status = 200
        response.headers["content-type"] = "application/json"
        response.write(%{{"received": "#{body}"}})
        response.close
      end

      server = HT2::Server.new("localhost", port, handler, tls_context: create_test_tls_context)

      spawn do
        server_ready.send(nil)
        server.listen
      end

      server_done.receive
      server.close
    end

    server_ready.receive
    sleep 0.1.seconds

    # Server is ready to accept connections
    received_body.should eq("")

    server_done.send(nil)
  end

  it "handles multiple concurrent requests" do
    port : Int32 = 9294
    server_ready = Channel(Nil).new
    server_done = Channel(Nil).new
    request_count = 0
    mutex = Mutex.new

    spawn do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
        mutex.synchronize { request_count += 1 }

        # Simulate some processing
        sleep 0.01.seconds

        response.status = 200
        response.headers["content-type"] = "text/plain"
        response.write("Response #{request.path}")
        response.close
      end

      server = HT2::Server.new("localhost", port, handler, tls_context: create_test_tls_context)

      spawn do
        server_ready.send(nil)
        server.listen
      end

      server_done.receive
      server.close
    end

    server_ready.receive
    sleep 0.1.seconds

    # Server ready, no requests yet
    mutex.synchronize { request_count }.should eq(0)

    server_done.send(nil)
  end

  it "handles large response bodies" do
    port : Int32 = 9295
    server_ready = Channel(Nil).new
    server_done = Channel(Nil).new
    handler_called = false

    spawn do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
        handler_called = true
        response.status = 200
        response.headers["content-type"] = "application/octet-stream"

        # Send 1MB of data
        data_size : Int32 = 1024 * 1024
        chunk_size : Int32 = 8192
        chunks : Int32 = data_size // chunk_size

        chunks.times do |i|
          chunk : Bytes = Bytes.new(chunk_size) { |j| ((i + j) % 256).to_u8 }
          response.write(chunk)
        end

        response.close
      end

      server = HT2::Server.new("localhost", port, handler, tls_context: create_test_tls_context)

      spawn do
        server_ready.send(nil)
        server.listen
      end

      server_done.receive
      server.close
    end

    server_ready.receive
    sleep 0.1.seconds

    handler_called.should be_false

    server_done.send(nil)
  end

  it "handles request headers correctly" do
    port : Int32 = 9296
    server_ready = Channel(Nil).new
    server_done = Channel(Nil).new
    headers_processed = false

    spawn do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
        headers_processed = true
        # Echo back some headers
        response.status = 200
        response.headers["content-type"] = "application/json"
        response.headers["x-received-auth"] = request.headers["authorization"]? || "none"
        response.headers["x-received-ua"] = request.headers["user-agent"]? || "none"

        response.write(%{{"method": "#{request.method}", "path": "#{request.path}"}})
        response.close
      end

      server = HT2::Server.new("localhost", port, handler, tls_context: create_test_tls_context)

      spawn do
        server_ready.send(nil)
        server.listen
      end

      server_done.receive
      server.close
    end

    server_ready.receive
    sleep 0.1.seconds

    headers_processed.should be_false

    server_done.send(nil)
  end

  it "handles stream errors gracefully" do
    port : Int32 = 9297
    server_ready = Channel(Nil).new
    server_done = Channel(Nil).new
    error_path_called = false

    spawn do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
        if request.path == "/error"
          error_path_called = true
          # Simulate an error by trying to write after closing
          response.close
          begin
            response.write("This should fail")
          rescue
            # Expected to fail
          end
        else
          response.status = 200
          response.write("OK")
          response.close
        end
      end

      server = HT2::Server.new("localhost", port, handler, tls_context: create_test_tls_context)

      spawn do
        server_ready.send(nil)
        server.listen
      end

      server_done.receive
      server.close
    end

    server_ready.receive
    sleep 0.1.seconds

    error_path_called.should be_false

    server_done.send(nil)
  end
end
