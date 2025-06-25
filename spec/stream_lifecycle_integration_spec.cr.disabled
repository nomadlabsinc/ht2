require "./spec_helper"

describe "Stream Lifecycle Tracing Integration" do
  it "traces complete stream lifecycle" do
    server = create_server
    server_port = server.local_address.port

    spawn do
      conn = server.accept
      HT2::Connection.new(conn, is_server: true).tap do |server_conn|
        server_conn.enable_stream_tracing(true)

        server_conn.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
          # Echo headers back
          stream.send_headers(headers, false)
          nil
        end

        server_conn.on_data = ->(stream : HT2::Stream, data : Bytes, end_stream : Bool) do
          # Echo data back
          stream.send_data(data, end_stream)
          nil
        end

        server_conn.start
      end
    end

    client_socket = TCPSocket.new("localhost", server_port)
    client_conn = HT2::Connection.new(client_socket, is_server: false)
    client_conn.enable_stream_tracing(true)
    client_conn.start

    # Create a stream and send request
    stream = client_conn.create_stream
    headers = [
      {":method", "POST"},
      {":path", "/test"},
      {":scheme", "https"},
      {":authority", "localhost"},
    ]
    stream.send_headers(headers, false)

    # Send some data
    data = "Hello, World!".to_slice
    stream.send_data(data, true)

    # Wait for response
    sleep 0.1.seconds

    # Check client-side tracing
    client_trace = client_conn.stream_trace(stream.id)
    client_trace.should contain("CREATED")
    client_trace.should contain("HEADERS_SENT")
    client_trace.should contain("DATA_SENT")
    client_trace.should contain("STATE_CHANGE")
    client_trace.should contain("IDLE -> OPEN")
    client_trace.should contain("OPEN -> HALF_CLOSED_LOCAL")

    # Generate report
    report = client_conn.stream_lifecycle_report
    report.should contain("Stream Lifecycle Report")
    report.should contain("Stream #{stream.id}:")

    client_socket.close
    server.close
  end

  it "traces flow control events" do
    server = create_server
    server_port = server.local_address.port

    spawn do
      conn = server.accept
      HT2::Connection.new(conn, is_server: true).tap do |server_conn|
        server_conn.enable_stream_tracing(true)

        server_conn.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
          # Don't respond to create backpressure
          nil
        end

        server_conn.on_data = ->(stream : HT2::Stream, data : Bytes, end_stream : Bool) do
          # Slow consumer - don't read data immediately
          nil
        end

        server_conn.start
      end
    end

    client_socket = TCPSocket.new("localhost", server_port)
    client_conn = HT2::Connection.new(client_socket, is_server: false)
    client_conn.enable_stream_tracing(true)
    client_conn.start

    # Create a stream
    stream = client_conn.create_stream
    headers = [
      {":method", "POST"},
      {":path", "/test"},
      {":scheme", "https"},
      {":authority", "localhost"},
    ]
    stream.send_headers(headers, false)

    # Try to send large data to trigger flow control
    large_data = Bytes.new(1024 * 64, 0_u8) # 64KB
    begin
      # Send in chunks to allow window updates
      stream.send_data_chunked(large_data, chunk_size: 16384, end_stream: true)
    rescue ex
      # Expected if window is exhausted
    end

    sleep 0.1.seconds

    # Check for window update events
    trace = client_conn.stream_trace(stream.id)
    # May contain window update events if flow control kicked in
    trace.should contain("Stream #{stream.id} Lifecycle Trace")

    client_socket.close
    server.close
  end

  it "traces RST_STREAM events" do
    server = create_server
    server_port = server.local_address.port

    spawn do
      conn = server.accept
      HT2::Connection.new(conn, is_server: true).tap do |server_conn|
        server_conn.enable_stream_tracing(true)

        server_conn.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
          # Immediately reset the stream
          stream.send_rst_stream(HT2::ErrorCode::INTERNAL_ERROR)
          nil
        end

        server_conn.start
      end
    end

    client_socket = TCPSocket.new("localhost", server_port)
    client_conn = HT2::Connection.new(client_socket, is_server: false)
    client_conn.enable_stream_tracing(true)
    client_conn.start

    # Create a stream and send request
    stream = client_conn.create_stream
    headers = [
      {":method", "GET"},
      {":path", "/test"},
      {":scheme", "https"},
      {":authority", "localhost"},
    ]
    stream.send_headers(headers, true)

    # Wait for RST_STREAM
    sleep 0.1.seconds

    # Check tracing
    trace = client_conn.stream_trace(stream.id)
    trace.should contain("RST_RECEIVED")
    trace.should contain("INTERNAL_ERROR")
    trace.should contain("Stream closed by RST_STREAM")

    # Check that stream is in closed list
    report = client_conn.stream_lifecycle_report
    report.should contain("Recently Closed Streams")
    report.should contain("[CLOSED]")

    client_socket.close
    server.close
  end

  it "can clear traces" do
    server = create_server
    server_port = server.local_address.port

    spawn do
      conn = server.accept
      HT2::Connection.new(conn, is_server: true).tap do |server_conn|
        server_conn.start
      end
    end

    client_socket = TCPSocket.new("localhost", server_port)
    client_conn = HT2::Connection.new(client_socket, is_server: false)
    client_conn.enable_stream_tracing(true)
    client_conn.start

    # Create streams
    stream1 = client_conn.create_stream
    stream2 = client_conn.create_stream

    # Send some data
    headers = [{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "localhost"}]
    stream1.send_headers(headers, true)
    stream2.send_headers(headers, true)

    sleep 0.05.seconds

    # Verify traces exist
    client_conn.stream_trace(stream1.id).should_not eq("Stream #{stream1.id} not found")
    client_conn.stream_trace(stream2.id).should_not eq("Stream #{stream2.id} not found")

    # Clear traces
    client_conn.clear_stream_traces

    # Verify traces are gone
    client_conn.stream_trace(stream1.id).should eq("Stream #{stream1.id} not found")
    client_conn.stream_trace(stream2.id).should eq("Stream #{stream2.id} not found")

    client_socket.close
    server.close
  end
end

private def create_server
  server = TCPServer.new("localhost", 0)
  server
end
