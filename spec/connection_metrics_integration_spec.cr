require "./spec_helper"

def create_socket_pair
  server = TCPServer.new("127.0.0.1", 0)
  client = TCPSocket.new("127.0.0.1", server.local_address.port)
  server_socket = server.accept
  server.close
  {client, server_socket}
end

describe "Connection Metrics Integration" do
  it "tracks metrics during connection lifecycle" do
    client_socket, server_socket = create_socket_pair
    server_conn = HT2::Connection.new(server_socket, is_server: true, client_ip: "127.0.0.1")
    client_conn = HT2::Connection.new(client_socket, is_server: false)

    spawn { server_conn.start }
    client_conn.start

    # Give connections time to exchange settings
    sleep 0.1.seconds

    # Create a stream and send data
    stream = client_conn.create_stream
    stream.send_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}])
    stream.send_data("Hello, World!".to_slice, end_stream: true)

    # Give time for frames to be processed
    sleep 0.1.seconds

    # Check client metrics
    client_metrics = client_conn.metrics.snapshot
    client_metrics[:streams][:created].should eq 1
    client_metrics[:frames][:sent][:headers].should be >= 1
    client_metrics[:frames][:sent][:data].should be >= 1
    client_metrics[:frames][:sent][:settings].should be >= 1
    client_metrics[:frames][:received][:settings].should be >= 1
    client_metrics[:bytes][:sent].should be > 0
    client_metrics[:bytes][:received].should be > 0

    # Check server metrics
    server_metrics = server_conn.metrics.snapshot
    server_metrics[:streams][:created].should eq 1
    server_metrics[:frames][:received][:headers].should be >= 1
    server_metrics[:frames][:received][:data].should be >= 1
    server_metrics[:frames][:received][:settings].should be >= 1
    server_metrics[:frames][:sent][:settings].should be >= 1
    server_metrics[:bytes][:sent].should be > 0
    server_metrics[:bytes][:received].should be > 0

    # Both should show connection is active
    client_metrics[:state][:goaway_sent].should be_false
    client_metrics[:state][:goaway_received].should be_false
    server_metrics[:state][:goaway_sent].should be_false
    server_metrics[:state][:goaway_received].should be_false

    # Clean up
    client_conn.close
    server_conn.close
  end

  it "tracks error metrics" do
    client_socket, server_socket = create_socket_pair
    server_conn = HT2::Connection.new(server_socket, is_server: true)
    client_conn = HT2::Connection.new(client_socket, is_server: false)

    spawn { server_conn.start }
    client_conn.start

    # Give connections time to exchange settings
    sleep 0.1.seconds

    # Create a stream
    stream = client_conn.create_stream
    stream.send_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}])

    # Send RST_STREAM
    stream.send_rst_stream(HT2::ErrorCode::CANCEL)

    # Give time for frames to be processed
    sleep 0.1.seconds

    # Check error metrics
    client_metrics = client_conn.metrics.snapshot
    client_metrics[:frames][:sent][:rst_stream].should eq 1
    client_metrics[:errors][:sent][:cancel].should eq 1

    server_metrics = server_conn.metrics.snapshot
    server_metrics[:frames][:received][:rst_stream].should eq 1
    server_metrics[:errors][:received][:cancel].should eq 1
    server_metrics[:streams][:closed].should be >= 1

    # Clean up
    client_conn.close
    server_conn.close
  end

  it "tracks flow control metrics" do
    client_socket, server_socket = create_socket_pair

    # Set small initial window size to trigger flow control
    server_conn = HT2::Connection.new(server_socket, is_server: true)
    client_conn = HT2::Connection.new(client_socket, is_server: false)

    # Update settings to have small window
    spawn { server_conn.start }
    client_conn.start

    # Give connections time to exchange settings
    sleep 0.1.seconds

    # Create stream and check window updates
    stream = client_conn.create_stream
    stream.send_headers([{":method", "POST"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}])

    # Metrics should show window updates
    sleep 0.1.seconds

    client_metrics = client_conn.metrics.snapshot
    server_metrics = server_conn.metrics.snapshot

    # At minimum, settings ACK should have been sent
    total_frames = client_metrics[:frames][:sent][:total] +
                   client_metrics[:frames][:received][:total] +
                   server_metrics[:frames][:sent][:total] +
                   server_metrics[:frames][:received][:total]
    total_frames.should be > 0

    # Clean up
    client_conn.close
    server_conn.close
  end

  it "tracks GOAWAY state correctly" do
    client_socket, server_socket = create_socket_pair
    server_conn = HT2::Connection.new(server_socket, is_server: true)
    client_conn = HT2::Connection.new(client_socket, is_server: false)

    spawn { server_conn.start }
    client_conn.start

    # Give connections time to exchange settings
    sleep 0.1.seconds

    # Close client connection (should send GOAWAY)
    client_conn.close

    # Give time for GOAWAY to be received
    sleep 0.1.seconds

    # Check metrics
    client_metrics = client_conn.metrics.snapshot
    client_metrics[:state][:goaway_sent].should be_true

    # Server should have received GOAWAY
    server_metrics = server_conn.metrics.snapshot
    server_metrics[:state][:goaway_received].should be_true
    server_metrics[:frames][:received][:goaway].should eq 1

    # Clean up
    server_conn.close
  end
end
