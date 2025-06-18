require "openssl"
require "uri"
require "./connection"
require "./request"
require "./response"

module HT2
  class Client
    class ClientConnection
      getter connection : Connection
      getter host : String
      getter port : Int32
      getter scheme : String
      getter created_at : Time
      property last_used_at : Time

      def initialize(@connection : Connection, @host : String, @port : Int32, @scheme : String)
        @created_at = Time.utc
        @last_used_at = Time.utc
      end

      def healthy? : Bool
        return false if @connection.goaway_sent? || @connection.goaway_received?

        # Check stream capacity
        active_streams = @connection.streams.count { |_, stream| !stream.closed? }
        max_streams = @connection.remote_settings[SettingsParameter::MAX_CONCURRENT_STREAMS]
        active_streams < max_streams
      end

      def close : Nil
        @connection.close
      end
    end

    getter max_connections_per_host : Int32
    getter connection_timeout : Time::Span
    getter idle_timeout : Time::Span

    def initialize(
      @max_connections_per_host : Int32 = 2,
      @connection_timeout : Time::Span = 10.seconds,
      @idle_timeout : Time::Span = 5.minutes,
      @tls_context : OpenSSL::SSL::Context::Client? = nil,
    )
      @connections = Hash(String, Array(ClientConnection)).new { |hash, key| hash[key] = [] of ClientConnection }
      @mutex = Mutex.new
      @response_channels = Hash(UInt32, Channel(ClientResponse)).new
    end

    def get(url : String, headers : Hash(String, String) = {} of String => String) : ClientResponse
      request("GET", url, headers)
    end

    def post(url : String, body : String | Bytes | Nil = nil,
             headers : Hash(String, String) = {} of String => String) : ClientResponse
      request("POST", url, headers, body)
    end

    def put(url : String, body : String | Bytes | Nil = nil,
            headers : Hash(String, String) = {} of String => String) : ClientResponse
      request("PUT", url, headers, body)
    end

    def delete(url : String, headers : Hash(String, String) = {} of String => String) : ClientResponse
      request("DELETE", url, headers)
    end

    def head(url : String, headers : Hash(String, String) = {} of String => String) : ClientResponse
      request("HEAD", url, headers)
    end

    def close : Nil
      @mutex.synchronize do
        @connections.each_value do |conn_list|
          conn_list.each(&.close)
        end
        @connections.clear
      end
    end

    def warm_up(url : String, count : Int32 = 1) : Nil
      uri = URI.parse(url)
      raise ArgumentError.new("Invalid URL: #{url}") unless uri.host

      host = uri.host || raise ArgumentError.new("URL must have a host")
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      scheme = uri.scheme || "https"
      connection_key = "#{host}:#{port}"

      @mutex.synchronize do
        connections = @connections[connection_key]

        # Create warm connections up to the limit
        (count - connections.size).times do
          break if connections.size >= @max_connections_per_host

          begin
            conn = create_connection(host, port, scheme)
            connections << conn
          rescue ex
            # Log and continue
          end
        end
      end
    end

    def drain_connections(host : String? = nil) : Nil
      @mutex.synchronize do
        if host
          if conn_list = @connections["#{host}:443"]?
            drain_connection_list(conn_list)
          end
          if conn_list = @connections["#{host}:80"]?
            drain_connection_list(conn_list)
          end
        else
          @connections.each_value do |connections_to_drain|
            drain_connection_list(connections_to_drain)
          end
        end
      end
    end

    private def drain_connection_list(connections : Array(ClientConnection)) : Nil
      connections.each do |conn|
        # Send GOAWAY to gracefully close
        conn.connection.send_goaway(ErrorCode::NO_ERROR, "Client closing")
      end

      # Wait for streams to complete (up to 5 seconds)
      deadline = Time.utc + 5.seconds
      while Time.utc < deadline
        if connections.all?(&.connection.streams.empty?)
          break
        end
        sleep 0.1.seconds
      end

      # Close all connections
      connections.each(&.close)
      connections.clear
    end

    # Test helper to access connections
    {% if env("CRYSTAL_SPEC") %}
      def connections : Hash(String, Array(ClientConnection))
        @connections
      end
    {% end %}

    private def request(method : String, url : String, headers : Hash(String, String),
                        body : String | Bytes | Nil = nil) : ClientResponse
      uri = URI.parse(url)
      raise ArgumentError.new("Invalid URL: #{url}") unless uri.host

      connection = get_connection(uri)
      stream = connection.connection.create_stream

      # Build headers
      request_headers = [
        {":method", method},
        {":scheme", uri.scheme || "https"},
        {":authority", uri.host || raise ArgumentError.new("URL must have a host")},
        {":path", uri.path || "/"},
      ]

      headers.each do |name, value|
        request_headers << {name.downcase, value}
      end

      # Send headers
      end_stream = body.nil?
      stream.send_headers(request_headers, end_stream)

      # Send body if present
      if body
        data = case body
               when String
                 body.to_slice
               when Bytes
                 body
               else
                 raise ArgumentError.new("Invalid body type")
               end
        stream.send_data(data, true)
      end

      # Create response channel
      response_channel = Channel(ClientResponse).new
      @response_channels[stream.id] = response_channel

      # Wait for response
      response = response_channel.receive
      @response_channels.delete(stream.id)

      # Update last used time
      connection.last_used_at = Time.utc

      response
    end

    private def get_connection(uri : URI) : ClientConnection
      host = uri.host || raise ArgumentError.new("URL must have a host")
      port = uri.port || (uri.scheme == "https" ? 443 : 80)
      scheme = uri.scheme || "https"
      connection_key = "#{host}:#{port}"

      @mutex.synchronize do
        connections = @connections[connection_key]

        # Clean up unhealthy connections
        connections.reject! do |conn|
          if !conn.healthy? || (Time.utc - conn.last_used_at) > @idle_timeout
            conn.close rescue nil
            true
          else
            false
          end
        end

        # Find available connection
        if conn = connections.find(&.healthy?)
          return conn
        end

        # Create new connection if under limit
        if connections.size < @max_connections_per_host
          conn = create_connection(host, port, scheme)
          connections << conn
          return conn
        end

        # Wait for available connection
        raise ConnectionError.new(ErrorCode::REFUSED_STREAM, "No available connections to #{connection_key}")
      end
    end

    private def create_connection(host : String, port : Int32, scheme : String) : ClientConnection
      socket = TCPSocket.new(host, port, connect_timeout: @connection_timeout)

      # Wrap with TLS if HTTPS
      if scheme == "https"
        tls_context = @tls_context || default_tls_context
        tls_socket = OpenSSL::SSL::Socket::Client.new(socket, tls_context, hostname: host)
        tls_socket.sync_close = true

        # Verify ALPN negotiation
        unless tls_socket.alpn_protocol == "h2"
          tls_socket.close
          raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "Server does not support HTTP/2")
        end

        connection = Connection.new(tls_socket, is_server: false)
      else
        connection = Connection.new(socket, is_server: false)
      end

      # Set up response callbacks
      setup_callbacks(connection)

      # Start connection
      connection.start

      ClientConnection.new(connection, host, port, scheme)
    end

    private def setup_callbacks(connection : Connection) : Nil
      connection.on_headers = ->(stream : Stream, headers : Array(Tuple(String, String)), _end_stream : Bool) do
        if channel = @response_channels[stream.id]?
          response = ClientResponse.new(stream, headers)
          channel.send(response)
        end
      end

      connection.on_data = ->(_stream : Stream, _data : Bytes, _end_stream : Bool) do
        # Data is accumulated in the stream
      end
    end

    private def default_tls_context : OpenSSL::SSL::Context::Client
      context = OpenSSL::SSL::Context::Client.new
      context.alpn_protocol = "h2"
      context.verify_mode = OpenSSL::SSL::VerifyMode::PEER
      context
    end
  end

  # Client-specific response implementation
  class ClientResponse < Response
    @response_headers : Hash(String, String)

    def initialize(@stream : Stream, header_list : Array(Tuple(String, String)))
      super(@stream)
      @response_headers = Hash(String, String).new

      header_list.each do |name, value|
        if name == ":status"
          @status = value.to_i
        else
          @response_headers[name] = value
          # Also add to HTTP::Headers for compatibility
          @headers[name] = value
        end
      end
    end

    def body : String
      String.new(body_bytes)
    end

    def body_bytes : Bytes
      @stream.received_data
    end
  end
end
