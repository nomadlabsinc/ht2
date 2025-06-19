require "openssl"
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

      # Configure ALPN for HTTP/2 if TLS is enabled
      if context = @tls_context
        context.alpn_protocol = "h2"
      end
    end

    def listen : Nil
      @server = server = TCPServer.new(@host, @port)
      @running = true
      @worker_pool.start

      puts "HTTP/2 server listening on #{@host}:#{@port}"

      while @running
        begin
          client = server.accept?
          break unless client

          spawn handle_client(client)
        rescue ex
          puts "Error accepting client: #{ex.message}"
        end
      end
    ensure
      close
    end

    def close : Nil
      @running = false
      @worker_pool.stop
      @server.try(&.close)
      @connections.each(&.close)
    end

    private def handle_client(socket : TCPSocket)
      # Extract client IP address
      client_ip = socket.remote_address.address

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
          puts "Client did not negotiate HTTP/2 via ALPN"
          client_socket.close
          return
        end
      end

      # Create HTTP/2 connection with client IP
      connection = Connection.new(client_socket, is_server: true, client_ip: client_ip)
      @connections << connection

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
      connection.on_headers = ->(stream : Stream, _headers : Array(Tuple(String, String)), end_stream : Bool) do
        if end_stream || stream.request_headers
          # We have complete headers, process request
          submit_stream_task(connection, stream)
        end
      end

      connection.on_data = ->(stream : Stream, _data : Bytes, end_stream : Bool) do
        # Data is accumulated in the stream
        if end_stream && stream.request_headers
          # Request is complete
          submit_stream_task(connection, stream)
        end
      end

      # Start connection
      connection.start
    rescue ex
      puts "Error handling client: #{ex.message}"
    ensure
      @connections.delete(connection) if connection
      begin
        client_socket.close if client_socket
      rescue ex : OpenSSL::SSL::Error | IO::Error
        # Socket already closed, ignore
      end
    end

    private def handle_h2c_client(socket : TCPSocket, client_ip : String)
      # For h2c, we'll handle HTTP/1.1 upgrade only for now
      # Direct prior knowledge support would require buffering
      handle_h2c_upgrade(socket, client_ip)
    rescue ex
      puts "Error in h2c handler: #{ex.message}"
      socket.close rescue nil
    end

    private def handle_h2c_prior_knowledge(socket : TCPSocket, client_ip : String)
      # Create HTTP/2 connection directly
      connection = Connection.new(socket, is_server: true, client_ip: client_ip)
      @connections << connection

      # Configure connection settings
      configure_connection(connection)

      # Start connection (will read preface)
      connection.start
    rescue ex
      puts "Error handling h2c prior knowledge: #{ex.message}"
    ensure
      @connections.delete(connection) if connection
    end

    private def handle_h2c_upgrade(socket : TCPSocket, client_ip : String)
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
        @connections << connection

        # Configure connection settings
        configure_connection(connection)

        # Apply remote settings from upgrade
        connection.apply_remote_settings(remote_settings) if remote_settings

        # Process the upgrade request as stream 1
        process_upgrade_request(connection, headers)

        # For h2c upgrade, start without reading preface
        # The connection has already been established via HTTP/1.1 upgrade
        connection.start_without_preface
      else
        # Not an upgrade request, send error
        send_http1_error(socket, 505, "HTTP Version Not Supported")
      end
    rescue ex
      puts "Error handling h2c upgrade: #{ex.message}"
    ensure
      @connections.delete(connection) if connection
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
      connection.on_headers = ->(stream : Stream, _headers : Array(Tuple(String, String)), end_stream : Bool) do
        if end_stream || stream.request_headers
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
      task = -> { handle_stream(connection, stream) }

      # Try to submit with a timeout to handle backpressure
      unless @worker_pool.try_submit(task, 100.milliseconds)
        # Worker pool is full, send 503 Service Unavailable
        begin
          response = Response.new(stream)
          response.status = 503
          response.headers["content-type"] = "text/plain"
          response.headers["retry-after"] = "5"
          response.write("Service temporarily unavailable".to_slice)
          response.close
        rescue
          # Best effort, ignore errors
        end
      end
    end

    private def handle_stream(connection : Connection, stream : Stream)
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
      # Send internal server error
      begin
        response = Response.new(stream)
        response.status = 500
        response.headers["content-type"] = "text/plain"
        response.write("Internal Server Error".to_slice)
        response.close
      rescue
        # Best effort, ignore errors
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
  end
end
