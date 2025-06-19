require "./spec_helper"

describe "H2C Prior Knowledge" do
  pending "handles h2c prior knowledge connections" do
    server = HT2::Server.new(
      enable_h2c: true,
      handler: ->(request : HT2::Request, response : HT2::Response) {
        response.status = 200
        response.headers["content-type"] = "text/plain"
        response.write("Prior knowledge: #{request.path}".to_slice)
      },
      host: "127.0.0.1",
      port: 0,
    )

    spawn do
      server.listen
    end

    # Wait for server to start
    sleep 0.1

    # Test prior knowledge client connection
    client = HT2::Client.new(
      enable_h2c: true,
      use_prior_knowledge: true
    )

    begin
      response = client.get("http://127.0.0.1:#{server.port}/test")
      response.status.should eq 200
      response.body.should eq "Prior knowledge: /test"
    ensure
      client.close
      server.close
    end
  end

  pending "falls back to upgrade when prior knowledge fails" do
    server = HT2::Server.new(
      enable_h2c: true,
      handler: ->(request : HT2::Request, response : HT2::Response) {
        response.status = 200
        response.headers["content-type"] = "text/plain"
        response.write("Upgrade: #{request.path}".to_slice)
      },
      host: "127.0.0.1",
      port: 0,
    )

    spawn do
      server.listen
    end

    # Wait for server to start
    sleep 0.1

    # Client without prior knowledge
    client = HT2::Client.new(
      enable_h2c: true,
      use_prior_knowledge: false
    )

    begin
      response = client.get("http://127.0.0.1:#{server.port}/fallback")
      response.status.should eq 200
      response.body.should eq "Upgrade: /fallback"
    ensure
      client.close
      server.close
    end
  end

  pending "caches h2c support per host" do
    request_count = 0

    server = HT2::Server.new(
      enable_h2c: true,
      handler: ->(request : HT2::Request, response : HT2::Response) {
        request_count += 1
        response.status = 200
        response.headers["content-type"] = "text/plain"
        response.write("Request #{request_count}".to_slice)
      },
      host: "127.0.0.1",
      port: 0,
    )

    spawn do
      server.listen
    end

    # Wait for server to start
    sleep 0.1

    client = HT2::Client.new(
      enable_h2c: true,
      use_prior_knowledge: false
    )

    begin
      # First request - should use upgrade
      response1 = client.get("http://127.0.0.1:#{server.port}/req1")
      response1.status.should eq 200

      # Second request - should use cached support info
      response2 = client.get("http://127.0.0.1:#{server.port}/req2")
      response2.status.should eq 200

      # Both requests should succeed
      response1.body.should eq "Request 1"
      response2.body.should eq "Request 2"
    ensure
      client.close
      server.close
    end
  end
end
