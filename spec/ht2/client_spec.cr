require "../spec_helper"

describe HT2::Client do
  describe "#initialize" do
    it "creates a client with default settings" do
      client = HT2::Client.new
      client.max_connections_per_host.should eq 2
      client.connection_timeout.should eq 10.seconds
      client.idle_timeout.should eq 5.minutes
    end

    it "creates a client with custom settings" do
      client = HT2::Client.new(
        max_connections_per_host: 5,
        connection_timeout: 30.seconds,
        idle_timeout: 10.minutes
      )
      client.max_connections_per_host.should eq 5
      client.connection_timeout.should eq 30.seconds
      client.idle_timeout.should eq 10.minutes
    end
  end

  describe "connection pooling" do
    pending "reuses connections for multiple requests to the same host"
    pending "creates multiple connections up to the limit"
    pending "respects max connections per host limit"
    pending "removes unhealthy connections from the pool"
    pending "removes idle connections after timeout"
  end

  describe "#warm_up" do
    pending "pre-establishes connections to a host"
    pending "respects max connections limit during warm-up"
  end

  describe "#drain_connections" do
    pending "gracefully closes all connections"
    pending "waits for active streams to complete"
    pending "drains connections for a specific host"
  end

  describe "HTTP methods" do
    pending "sends GET requests"
    pending "sends POST requests with body"
    pending "sends PUT requests with body"
    pending "sends DELETE requests"
    pending "sends HEAD requests"
  end

  describe "error handling" do
    it "handles connection failures" do
      client = HT2::Client.new
      expect_raises(Socket::Addrinfo::Error) do
        client.get("https://invalid.local.test:9999/")
      end
    end

    it "handles invalid URLs" do
      client = HT2::Client.new
      expect_raises(ArgumentError, "Invalid URL: not-a-url") do
        client.get("not-a-url")
      end
    end

    pending "handles servers that don't support HTTP/2"
  end
end
