require "./spec_helper"
require "h2o"
require "openssl"

# Helper to create self-signed certificate for testing
def create_test_tls_context : OpenSSL::SSL::Context::Server
  context = OpenSSL::SSL::Context::Server.new

  # Generate self-signed certificate
  key = OpenSSL::PKey::RSA.new(2048)
  cert = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = 1
  cert.subject = OpenSSL::X509::Name.new([["CN", "localhost"]])
  cert.issuer = cert.subject
  cert.public_key = key.public_key
  cert.not_before = Time.utc
  cert.not_after = Time.utc + 365.days

  # Sign certificate
  cert.sign(key, OpenSSL::Digest.new("SHA256"))

  # Configure context
  context.certificate_chain = cert.to_pem
  context.private_key = key.to_pem
  context.alpn_protocol = "h2"

  context
end

describe "HT2 Integration Tests" do
  it "handles basic GET request" do
    port : Int32 = 9292
    server_ready = Channel(Nil).new
    server_done = Channel(Nil).new

    # Start server
    spawn do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
        response.status = 200
        response.headers["content-type"] = "text/plain"
        response.write("Hello from HTTP/2!")
        response.close
      end

      server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

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
    sleep 0.1

    # Make request with h2o client
    begin
      client = H2O::Client.new(
        host: "localhost",
        port: port,
        tls: true,
        tls_verify_mode: OpenSSL::SSL::VerifyMode::NONE,
        timeout: 1.seconds
      )

      response = client.get("/")
      response.status.should eq(200)
      response.body.should eq("Hello from HTTP/2!")
      response.headers["content-type"]?.should eq("text/plain")

      client.close
    ensure
      server_done.send(nil)
    end
  end

  it "handles POST request with body" do
    port : Int32 = 9293
    server_ready = Channel(Nil).new
    server_done = Channel(Nil).new

    spawn do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
        body : String = request.body.gets_to_end

        response.status = 200
        response.headers["content-type"] = "application/json"
        response.write(%{{"received": "#{body}"}})
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
    sleep 0.1

    begin
      client = H2O::Client.new(
        host: "localhost",
        port: port,
        tls: true,
        tls_verify_mode: OpenSSL::SSL::VerifyMode::NONE,
        timeout: 1.seconds
      )

      response = client.post("/api/data", body: "test data")
      response.status.should eq(200)
      response.body.should eq(%{{"received": "test data"}})

      client.close
    ensure
      server_done.send(nil)
    end
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
        sleep 0.01

        response.status = 200
        response.headers["content-type"] = "text/plain"
        response.write("Response #{request.path}")
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
    sleep 0.1

    begin
      client = H2O::Client.new(
        host: "localhost",
        port: port,
        tls: true,
        tls_verify_mode: OpenSSL::SSL::VerifyMode::NONE,
        timeout: 1.seconds
      )

      # Send multiple concurrent requests
      channels = Array(Channel(H2O::Response)).new
      paths = ["/one", "/two", "/three", "/four", "/five"]

      paths.each do |path|
        channel = Channel(H2O::Response).new
        channels << channel

        spawn do
          response = client.get(path)
          channel.send(response)
        end
      end

      # Collect responses
      responses = channels.map(&.receive)

      responses.size.should eq(5)
      responses.each_with_index do |response, i|
        response.status.should eq(200)
        response.body.should eq("Response #{paths[i]}")
      end

      mutex.synchronize { request_count.should eq(5) }

      client.close
    ensure
      server_done.send(nil)
    end
  end

  it "handles large response bodies" do
    port : Int32 = 9295
    server_ready = Channel(Nil).new
    server_done = Channel(Nil).new

    spawn do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
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

      server = HT2::Server.new("localhost", port, handler, create_test_tls_context)

      spawn do
        server_ready.send(nil)
        server.listen
      end

      server_done.receive
      server.close
    end

    server_ready.receive
    sleep 0.1

    begin
      client = H2O::Client.new(
        host: "localhost",
        port: port,
        tls: true,
        tls_verify_mode: OpenSSL::SSL::VerifyMode::NONE,
        timeout: 5.seconds
      )

      response = client.get("/large")
      response.status.should eq(200)
      response.body.bytesize.should eq(1024 * 1024)

      client.close
    ensure
      server_done.send(nil)
    end
  end

  it "handles request headers correctly" do
    port : Int32 = 9296
    server_ready = Channel(Nil).new
    server_done = Channel(Nil).new

    spawn do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
        # Echo back some headers
        response.status = 200
        response.headers["content-type"] = "application/json"
        response.headers["x-received-auth"] = request.headers["authorization"]? || "none"
        response.headers["x-received-ua"] = request.headers["user-agent"]? || "none"

        response.write(%{{"method": "#{request.method}", "path": "#{request.path}"}})
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
    sleep 0.1

    begin
      client = H2O::Client.new(
        host: "localhost",
        port: port,
        tls: true,
        tls_verify_mode: OpenSSL::SSL::VerifyMode::NONE,
        timeout: 1.seconds
      )

      headers = HTTP::Headers{
        "Authorization" => "Bearer test-token",
        "User-Agent"    => "TestClient/1.0",
      }

      response = client.get("/test", headers: headers)
      response.status.should eq(200)
      response.headers["x-received-auth"]?.should eq("Bearer test-token")
      response.headers["x-received-ua"]?.should eq("TestClient/1.0")

      body = JSON.parse(response.body)
      body["method"].should eq("GET")
      body["path"].should eq("/test")

      client.close
    ensure
      server_done.send(nil)
    end
  end

  it "handles stream errors gracefully" do
    port : Int32 = 9297
    server_ready = Channel(Nil).new
    server_done = Channel(Nil).new

    spawn do
      handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
        if request.path == "/error"
          # Simulate an error by trying to write after closing
          response.close
          response.write("This should fail")
        else
          response.status = 200
          response.write("OK")
          response.close
        end
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
    sleep 0.1

    begin
      client = H2O::Client.new(
        host: "localhost",
        port: port,
        tls: true,
        tls_verify_mode: OpenSSL::SSL::VerifyMode::NONE,
        timeout: 1.seconds
      )

      # Normal request should work
      response1 = client.get("/normal")
      response1.status.should eq(200)
      response1.body.should eq("OK")

      # Error request might fail, but shouldn't crash server
      begin
        response2 = client.get("/error")
        # If we get here, connection might have been reset
      rescue ex : H2O::Error
        # Expected - stream error
      end

      # Server should still handle subsequent requests
      response3 = client.get("/after-error")
      response3.status.should eq(200)
      response3.body.should eq("OK")

      client.close
    ensure
      server_done.send(nil)
    end
  end
end
