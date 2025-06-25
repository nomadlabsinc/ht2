require "./spec_helper"

describe "H2C Prior Knowledge" do
  it "handles h2c prior knowledge connections" do
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
    sleep 0.1.seconds

    begin
      # Test prior knowledge client connection using curl
      # --http2-prior-knowledge forces HTTP/2 without upgrade
      output = `curl -s --http2-prior-knowledge http://127.0.0.1:#{server.port}/test`
      status = $?.exit_code

      status.should eq 0
      output.should eq "Prior knowledge: /test"
    ensure
      server.close
    end
  end

  it "handles h2c upgrade from HTTP/1.1" do
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
    sleep 0.1.seconds

    begin
      # Test h2c upgrade using curl
      # --http2 allows upgrade from HTTP/1.1
      output = `curl -s --http2 http://127.0.0.1:#{server.port}/upgrade`
      status = $?.exit_code

      status.should eq 0
      output.should eq "Upgrade: /upgrade"
    ensure
      server.close
    end
  end

  it "serves HTTP/2 clients with different connection methods" do
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
    sleep 0.1.seconds

    begin
      # First request - HTTP/2 with upgrade
      output1 = `curl -s --http2 http://127.0.0.1:#{server.port}/req1`
      status1 = $?.exit_code

      status1.should eq 0
      output1.should eq "Request 1"

      # Second request - HTTP/2 with prior knowledge
      output2 = `curl -s --http2-prior-knowledge http://127.0.0.1:#{server.port}/req2`
      status2 = $?.exit_code

      status2.should eq 0
      output2.should eq "Request 2"
    ensure
      server.close
    end
  end
end
