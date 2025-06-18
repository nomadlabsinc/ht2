require "openssl"
require "./connection"

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

    @server : TCPServer?
    @running : Bool = false
    @connections : Set(Connection)

    def initialize(@host : String, @port : Int32, @handler : Handler,
                   @tls_context : OpenSSL::SSL::Context::Server? = nil,
                   @header_table_size : UInt32 = DEFAULT_HEADER_TABLE_SIZE,
                   @enable_push : Bool = false,
                   @max_concurrent_streams : UInt32 = DEFAULT_MAX_CONCURRENT_STREAMS,
                   @initial_window_size : UInt32 = DEFAULT_INITIAL_WINDOW_SIZE,
                   @max_frame_size : UInt32 = DEFAULT_MAX_FRAME_SIZE,
                   @max_header_list_size : UInt32 = DEFAULT_MAX_HEADER_LIST_SIZE)
      @connections = Set(Connection).new

      # Configure ALPN for HTTP/2 if TLS is enabled
      if context = @tls_context
        context.alpn_protocol = "h2"
      end
    end

    def listen : Nil
      @server = server = TCPServer.new(@host, @port)
      @running = true

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
      @server.try(&.close)
      @connections.each(&.close)
    end

    private def handle_client(socket : TCPSocket)
      # Extract client IP address
      client_ip = socket.remote_address.address

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
          spawn handle_stream(connection, stream)
        end
      end

      connection.on_data = ->(stream : Stream, _data : Bytes, end_stream : Bool) do
        # Data is accumulated in the stream
        if end_stream && stream.request_headers
          # Request is complete
          spawn handle_stream(connection, stream)
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
