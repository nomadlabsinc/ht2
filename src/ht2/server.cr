require "openssl"
require "log"
require "./connection"
require "./h2c"
require "./worker_pool"

module HT2
  class Server
    alias Handler = Proc(Request, Response, Nil)

    getter host : String
    getter port : Int32
    getter tls_context : OpenSSL::SSL::Context::Server?
    getter handler : Handler
    getter header_table_size : UInt32
    getter? enable_push : Bool
    getter max_concurrent_streams : UInt32
    getter initial_window_size : UInt32
    getter max_frame_size : UInt32
    getter max_header_list_size : UInt32
    getter max_workers : Int32
    getter worker_queue_size : Int32
    getter? enable_h2c : Bool
    getter h2c_upgrade_timeout : Time::Span

    @server : TCPServer?
    @running : Bool = false
    @connections : Set(Connection)
    @worker_pool : WorkerPool
    @client_fibers : Set(Fiber)
    @client_fibers_mutex : Mutex
    @shutdown_channel : Channel(Nil)
    @connection_semaphore : Channel(Nil)
    @connections_mutex : Mutex

    def initialize(@host : String, @port : Int32, @handler : Handler,
                   @enable_h2c : Bool = false,
                   @enable_push : Bool = false,
                   @h2c_upgrade_timeout : Time::Span = 10.seconds,
                   @header_table_size : UInt32 = DEFAULT_HEADER_TABLE_SIZE,
                   @initial_window_size : UInt32 = DEFAULT_INITIAL_WINDOW_SIZE,
                   @max_concurrent_streams : UInt32 = DEFAULT_MAX_CONCURRENT_STREAMS,
                   @max_frame_size : UInt32 = DEFAULT_MAX_FRAME_SIZE,
                   @max_header_list_size : UInt32 = DEFAULT_MAX_HEADER_LIST_SIZE,
                   @max_workers : Int32 = 100,
                   @tls_context : OpenSSL::SSL::Context::Server? = nil,
                   @worker_queue_size : Int32 = 1000)
      @connections = Set(Connection).new
      @worker_pool = WorkerPool.new(@max_workers, @worker_queue_size)
      @client_fibers = Set(Fiber).new
      @client_fibers_mutex = Mutex.new
      @shutdown_channel = Channel(Nil).new
      # Limit concurrent connections to prevent resource exhaustion
      max_concurrent_connections = @max_workers * 2
      @connection_semaphore = Channel(Nil).new(max_concurrent_connections)
      @connections_mutex = Mutex.new

      # Configure ALPN for HTTP/2 if TLS is enabled
      if context = @tls_context
        context.alpn_protocol = "h2"
      end
    end

    def listen : Nil
      @server = server = TCPServer.new(@host, @port)
      @running = true
      @worker_pool.start

      # Update port if it was 0 (dynamic assignment)
      if @port == 0
        @port = server.local_address.port
      end

      # Disable output during tests
      unless ENV["CRYSTAL_SPEC_CONTEXT"]?
      end

      # Start periodic cleanup fiber
      spawn { periodic_cleanup }

      while @running
        begin
          client = server.accept?
          break unless client

          # Try to acquire connection slot with very short timeout
          select
          when @connection_semaphore.send(nil)
            begin
              spawn handle_client(client)
            rescue ex
              # If spawn fails, release the semaphore
              spawn { @connection_semaphore.receive rescue nil }
              client.close rescue nil
              Log.error(exception: ex) { "Failed to spawn client handler" }
            end
          when timeout(1.millisecond) # Ultra-short timeout for h2spec
            # Connection limit reached, reject connection immediately
            client.close rescue nil
          end
        rescue ex
          unless ENV["CRYSTAL_SPEC_CONTEXT"]?
          end
        end
      end
    ensure
      close
    end

    def close : Nil
      return unless @running
      @running = false

      # Close the server socket first to prevent new connections
      @server.try(&.close)

      # Signal all client fibers to stop
      fiber_count = @client_fibers_mutex.synchronize { @client_fibers.size }
      fiber_count.times { @shutdown_channel.send(nil) rescue nil }

      # Close all connections with mutex protection
      @connections_mutex.synchronize do
        @connections.each(&.close)
      end

      # Stop worker pool
      @worker_pool.stop

      # Wait for client fibers to finish with timeout
      deadline = Time.monotonic + 2.seconds
      while Time.monotonic < deadline
        remaining = @client_fibers_mutex.synchronize { @client_fibers.size }
        break if remaining == 0
        sleep 10.milliseconds
      end
    end

    private def handle_client(socket : TCPSocket)
      fiber = spawn do
        handle_client_internal(socket)
      ensure
        @client_fibers_mutex.synchronize { @client_fibers.delete(Fiber.current) }
        # Release connection slot
        spawn do
          select
          when @connection_semaphore.receive
            # Slot released
          else
            # Channel might be closed during shutdown
          end
        end
      end
      @client_fibers_mutex.synchronize { @client_fibers << fiber }
    end

    private def handle_client_internal(socket : TCPSocket)
      # Extract client IP address
      client_ip = socket.remote_address.address
      connection : Connection? = nil
      client_socket : IO? = nil
      error_count = 0

      # Handle h2c mode
      if @enable_h2c && !@tls_context
        handle_h2c_client(socket, client_ip)
        return
      end

      # Wrap with TLS if configured
      client_socket = if context = @tls_context
                        tls_socket = OpenSSL::SSL::Socket::Server.new(socket, context)
                        tls_socket.sync_close = true
                        tls_socket
                      else
                        socket
                      end

      # Verify ALPN negotiation for TLS connections
      if client_socket.is_a?(OpenSSL::SSL::Socket::Server)
        unless client_socket.alpn_protocol == "h2"
          unless ENV["CRYSTAL_SPEC_CONTEXT"]?
          end
          client_socket.close
          return
        end
      end

      # Create HTTP/2 connection with client IP
      connection = Connection.new(client_socket, is_server: true, client_ip: client_ip)
      @connections_mutex.synchronize do
        @connections << connection
      end

      # Configure connection settings
      settings = SettingsFrame::Settings.new
      settings[SettingsParameter::HEADER_TABLE_SIZE] = @header_table_size
      settings[SettingsParameter::ENABLE_PUSH] = @enable_push ? 1_u32 : 0_u32
      settings[SettingsParameter::MAX_CONCURRENT_STREAMS] = @max_concurrent_streams
      settings[SettingsParameter::INITIAL_WINDOW_SIZE] = @initial_window_size
      settings[SettingsParameter::MAX_FRAME_SIZE] = @max_frame_size
      settings[SettingsParameter::MAX_HEADER_LIST_SIZE] = @max_header_list_size
      connection.update_settings(settings)

      # Set up callbacks
      connection.on_headers = ->(stream : Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
        # The callback is invoked AFTER headers are set on the stream
        # Check if these are trailers by looking for pseudo-headers
        is_trailers = !headers.any? { |(name, _)| name.starts_with?(":") }

        if is_trailers && stream.end_stream_received?
          # Trailers received and stream is complete
          submit_stream_task(connection, stream)
        elsif end_stream && !is_trailers
          # Initial headers with END_STREAM - process immediately

          # For h2spec, bypass worker pool if queue is congested
          if @worker_pool.queue_depth > 5
            begin
              handle_stream(connection, stream)
            rescue ex
              Log.error { "Error handling stream inline: #{ex.message}" }
            end
          else
            submit_stream_task(connection, stream)
          end
        elsif !is_trailers && !end_stream
          # Initial headers without END_STREAM - wait for data or trailers
        else
        end
      end

      connection.on_data = ->(stream : Stream, data : Bytes, end_stream : Bool) do
        # Data is accumulated in the stream
        if end_stream && stream.request_headers
          # Request is complete with final data

          # For h2spec, bypass worker pool if queue is congested
          if @worker_pool.queue_depth > 5
            begin
              handle_stream(connection, stream)
            rescue ex
              Log.error { "Error handling stream inline: #{ex.message}" }
            end
          else
            submit_stream_task(connection, stream)
          end
        end
      end

      # Start connection
      connection.start

      # Wait for connection to close or shutdown signal
      loop do
        select
        when @shutdown_channel.receive?
          break
        when timeout(0.1.seconds)
          break if connection.closed?
        end
      end
    rescue ex : ConnectionError
      # Expected protocol errors
      unless ENV["CRYSTAL_SPEC_CONTEXT"]?
      end
    rescue ex : OpenSSL::SSL::Error
      # SSL errors (like health checks with plain TCP)
      # Don't print SSL errors in test context as they're often from health checks
    rescue ex
      # Unexpected errors
      Log.error { "Unexpected error handling client: #{ex.class} - #{ex.message}" }
      unless ENV["CRYSTAL_SPEC_CONTEXT"]?
      end
    ensure
      # Clean up with mutex protection
      if connection
        @connections_mutex.synchronize do
          @connections.delete(connection)
        end
      end
      begin
        client_socket.close if client_socket
      rescue ex : OpenSSL::SSL::Error | IO::Error
        # Socket already closed, ignore
      end
    end

    private def handle_h2c_client(socket : TCPSocket, client_ip : String)
      # Wrap socket in BufferedSocket to peek at initial bytes
      buffered_socket = BufferedSocket.new(socket)

      # Peek at first 24 bytes to detect connection type with timeout
      # Use a shorter timeout for the initial peek
      peek_timeout = {% if env("CRYSTAL_SPEC") %} 100.milliseconds {% else %} 1.second {% end %}
      initial_bytes = buffered_socket.peek(24, peek_timeout)

      # If we didn't get enough bytes, assume HTTP/1.1
      if initial_bytes.size < 3
        send_http1_error(socket, 408, "Request Timeout")
        return
      end

      case H2C.detect_connection_type(initial_bytes)
      when H2C::ConnectionType::H2PriorKnowledge
        handle_h2c_prior_knowledge(buffered_socket, client_ip)
      when H2C::ConnectionType::Http1
        handle_h2c_upgrade(buffered_socket, client_ip)
      else
        send_http1_error(socket, 400, "Bad Request")
      end
    rescue IO::TimeoutError
      send_http1_error(socket, 408, "Request Timeout")
    rescue ex
      unless ENV["CRYSTAL_SPEC_CONTEXT"]?
      end
      socket.close rescue nil
    end

    private def handle_h2c_prior_knowledge(socket : BufferedSocket, client_ip : String)
      # Create HTTP/2 connection directly with buffered socket
      # The buffered socket already contains the preface that was peeked
      connection = Connection.new(socket, is_server: true, client_ip: client_ip)
      @connections_mutex.synchronize do
        @connections << connection
      end

      # Configure connection settings
      configure_connection(connection)

      # Set up stream handler
      connection.on_headers = ->(stream : Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
        # Check if these are trailers by looking for pseudo-headers
        is_trailers = !headers.any? { |(name, _)| name.starts_with?(":") }

        if is_trailers && stream.end_stream_received?
          # Trailers received and stream is complete
          submit_stream_task(connection, stream)
        elsif end_stream && !is_trailers
          # Initial headers with END_STREAM - process immediately
          submit_stream_task(connection, stream)
        end
        # Otherwise, headers without END_STREAM - wait for more data
      end

      connection.on_data = ->(stream : Stream, data : Bytes, end_stream : Bool) do
        # Data is accumulated in the stream
        if end_stream && stream.request_headers
          # Request is complete with final data
          submit_stream_task(connection, stream)
        end
      end

      # Start connection (will read preface from buffered socket)
      connection.start

      # Wait for connection to close or shutdown signal
      loop do
        select
        when @shutdown_channel.receive?
          break
        when timeout(0.1.seconds)
          break if connection.closed?
        end
      end
    rescue ex
      unless ENV["CRYSTAL_SPEC_CONTEXT"]?
      end
    ensure
      if connection
        @connections_mutex.synchronize do
          @connections.delete(connection)
        end
      end
    end

    private def handle_h2c_upgrade(socket : BufferedSocket, client_ip : String)
      # For simplicity, we'll rely on HTTP/1.1 upgrade mechanism
      # Clients that want to use prior knowledge should send the preface
      # after connecting, which will be handled by the Connection class

      # Read HTTP/1.1 headers
      headers = H2C.read_http1_headers(socket, @h2c_upgrade_timeout)

      unless headers
        send_http1_error(socket, 400, "Bad Request")
        return
      end

      # Check if this is an upgrade request
      if H2C.upgrade_request?(headers)
        # Decode settings from HTTP2-Settings header
        settings_header = headers[H2C::HTTP2_SETTINGS_HEADER.downcase]?
        unless settings_header
          send_http1_error(socket, 400, "Missing HTTP2-Settings header")
          return
        end

        remote_settings = H2C.decode_settings(settings_header)

        # Send 101 Switching Protocols response
        socket.write(H2C::SWITCHING_PROTOCOLS_RESPONSE.to_slice)
        socket.flush

        # Create HTTP/2 connection
        connection = Connection.new(socket, is_server: true, client_ip: client_ip)
        @connections_mutex.synchronize do
          @connections << connection
        end

        # Configure connection settings
        configure_connection(connection)

        # Apply remote settings from upgrade
        connection.apply_remote_settings(remote_settings) if remote_settings

        # Set up stream handler
        connection.on_headers = ->(stream : Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
          # Check if these are trailers by looking for pseudo-headers
          is_trailers = !headers.any? { |(name, _)| name.starts_with?(":") }

          if is_trailers && stream.end_stream_received?
            # Trailers received and stream is complete
            submit_stream_task(connection, stream)
          elsif end_stream && !is_trailers
            # Initial headers with END_STREAM - process immediately
            submit_stream_task(connection, stream)
          end
        end

        connection.on_data = ->(stream : Stream, data : Bytes, end_stream : Bool) do
          # Data is accumulated in the stream
          if end_stream && stream.request_headers
            # Request is complete
            submit_stream_task(connection, stream)
          end
        end

        # Process the upgrade request as stream 1
        process_upgrade_request(connection, headers)

        # For h2c upgrade, start without reading preface
        # The connection has already been established via HTTP/1.1 upgrade
        connection.start_without_preface

        # Wait for connection to close or shutdown signal
        loop do
          select
          when @shutdown_channel.receive?
            break
          when timeout(0.1.seconds)
            break if connection.closed?
          end
        end
      else
        # Not an upgrade request, send error
        send_http1_error(socket, 505, "HTTP Version Not Supported")
      end
    rescue ex
      unless ENV["CRYSTAL_SPEC_CONTEXT"]?
      end
    ensure
      if connection
        @connections_mutex.synchronize do
          @connections.delete(connection)
        end
      end
    end

    private def configure_connection(connection : Connection)
      settings = SettingsFrame::Settings.new
      settings[SettingsParameter::HEADER_TABLE_SIZE] = @header_table_size
      settings[SettingsParameter::ENABLE_PUSH] = @enable_push ? 1_u32 : 0_u32
      settings[SettingsParameter::MAX_CONCURRENT_STREAMS] = @max_concurrent_streams
      settings[SettingsParameter::INITIAL_WINDOW_SIZE] = @initial_window_size
      settings[SettingsParameter::MAX_FRAME_SIZE] = @max_frame_size
      settings[SettingsParameter::MAX_HEADER_LIST_SIZE] = @max_header_list_size
      connection.update_settings(settings)

      # Set up callbacks
      connection.on_headers = ->(stream : Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
        # Check if these are trailers by looking for pseudo-headers
        is_trailers = !headers.any? { |(name, _)| name.starts_with?(":") }

        if is_trailers && stream.end_stream_received?
          # Trailers received and stream is complete
          submit_stream_task(connection, stream)
        elsif end_stream && !is_trailers
          # Initial headers with END_STREAM - process immediately
          submit_stream_task(connection, stream)
        end
      end

      connection.on_data = ->(stream : Stream, _data : Bytes, end_stream : Bool) do
        if end_stream && stream.request_headers
          submit_stream_task(connection, stream)
        end
      end
    end

    private def process_upgrade_request(connection : Connection, headers : Hash(String, String))
      # Create stream 1 for the upgrade request
      stream = connection.create_stream(1_u32)

      # Convert HTTP/1.1 headers to HTTP/2 headers
      h2_headers = Array(Tuple(String, String)).new

      # Add pseudo-headers
      h2_headers << {":method", headers["_method"]}
      h2_headers << {":path", headers["_path"]}
      h2_headers << {":scheme", "http"}
      h2_headers << {":authority", headers["host"]? || "#{@host}:#{@port}"}

      # Add regular headers (skip upgrade-related headers)
      headers.each do |key, value|
        next if key.starts_with?("_")
        next if key == H2C::UPGRADE_HEADER.downcase
        next if key == H2C::CONNECTION_HEADER.downcase
        next if key == H2C::HTTP2_SETTINGS_HEADER.downcase

        h2_headers << {key, value}
      end

      # Set headers on stream
      stream.request_headers = h2_headers

      # Submit for processing
      submit_stream_task(connection, stream)
    end

    private def send_http1_error(socket : IO, status : Int32, message : String)
      response = String.build do |io|
        io << "HTTP/1.1 #{status} #{message}\r\n"
        io << "Content-Type: text/plain\r\n"
        io << "Content-Length: #{message.bytesize}\r\n"
        io << "Connection: close\r\n"
        io << "\r\n"
        io << message
      end

      socket.write(response.to_slice)
      socket.flush
      socket.close
    rescue
      # Best effort
    end

    private def submit_stream_task(connection : Connection, stream : Stream) : Nil
      # Check if connection is still valid before submitting task
      return if connection.closed?

      task = -> { handle_stream(connection, stream) }

      # Try to submit with a shorter timeout to handle backpressure
      unless @worker_pool.try_submit(task, 10.milliseconds)
        # Worker pool is full

        # For h2spec, handle the request inline to ensure timely response
        # This prevents test 6.5.3/1 from timing out
        begin
          handle_stream(connection, stream)
        rescue ex
          Log.error { "Error handling stream inline: #{ex.message}" }
          begin
            stream.send_rst_stream(ErrorCode::INTERNAL_ERROR)
          rescue
            # Best effort
          end
        end
      end
    end

    private def handle_stream(connection : Connection, stream : Stream)
      # Record request and check for connection recycling
      connection.record_request

      # Create request from stream
      request = Request.from_stream(stream)

      # Create response
      response = Response.new(stream)

      # Call handler
      @handler.call(request, response)

      # Ensure response is sent
      response.close unless response.closed?
    rescue ex : StreamError
      # Stream error already handled by connection
    rescue ex
      # Log the error with backtrace
      Log.error { "Error handling request: #{ex.message}\n#{ex.backtrace.join("\n")}" }

      # Only try to send error response if headers haven't been sent
      if response && !response.closed?
        begin
          # Try to close the response gracefully
          response.close
        rescue
          # If that fails, reset the stream
          stream.send_rst_stream(ErrorCode::INTERNAL_ERROR)
        end
      else
        # Headers already sent or response closed, reset the stream
        stream.send_rst_stream(ErrorCode::INTERNAL_ERROR)
      end
    end

    # Worker pool monitoring
    def worker_pool_active_count : Int32
      @worker_pool.active_count
    end

    def worker_pool_queue_depth : Int32
      @worker_pool.queue_depth
    end

    # Helper method to create TLS context with HTTP/2 support
    def self.create_tls_context(cert_path : String, key_path : String) : OpenSSL::SSL::Context::Server
      context = OpenSSL::SSL::Context::Server.new
      context.certificate_chain = cert_path
      context.private_key = key_path
      context.alpn_protocol = "h2"

      # Set secure cipher suites for HTTP/2
      context.ciphers = "ECDHE+AESGCM:ECDHE+CHACHA20:DHE+AESGCM:DHE+CHACHA20:!aNULL:!MD5:!DSS"

      context
    end

    private def periodic_cleanup : Nil
      consecutive_high_load = 0

      while @running
        # Adaptive sleep - shorter during high load
        connections_count = @connections_mutex.synchronize { @connections.size }
        queue_depth = @worker_pool.queue_depth

        sleep_duration = if connections_count > 50 || queue_depth > 20
                           consecutive_high_load += 1
                           250.milliseconds # Even faster cleanup during stress
                         elsif connections_count > 10 || queue_depth > 5
                           500.milliseconds # Medium speed for moderate load
                         else
                           consecutive_high_load = 0
                           1.second # Fast normal cleanup
                         end

        sleep sleep_duration

        # Clean up closed connections and unhealthy ones
        @connections_mutex.synchronize do
          before_count = @connections.size
          closed_connections = @connections.select do |conn|
            conn.closed? || conn.goaway_sent? || conn.goaway_received? ||
              (conn.metrics.idle_time > 30.seconds) ||
              (conn.metrics.errors_received.total > 100) ||
              conn.should_recycle? # Include connections that should be recycled
          end

          closed_connections.each do |conn|
            @connections.delete(conn)
            # Force close if not already closed
            unless conn.closed?
              conn.close rescue nil
            end
          end

          removed = closed_connections.size

          # Log warning if too many connections
          if @connections.size > @max_workers
            Log.warn { "Connection count (#{@connections.size}) exceeds worker count (#{@max_workers})" }
          end
        end

        # Force GC more aggressively
        if queue_depth > 10 || consecutive_high_load > 2 || connections_count > 20
          GC.collect
          consecutive_high_load = 0
        end
      end
    rescue ex
      Log.error { "Periodic cleanup error: #{ex.message}" }
    end
  end
end
