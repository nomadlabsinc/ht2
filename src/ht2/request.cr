require "http"
require "uri"

module HT2
  class Request
    getter method : String
    getter path : String
    getter authority : String?
    getter scheme : String
    getter headers : HTTP::Headers
    getter body : IO
    getter version : String

    def initialize(@method : String, @path : String, @headers : HTTP::Headers, @body : IO,
                   @scheme : String = "https", @authority : String? = nil)
      @version = "HTTP/2"
    end

    # Create request from HTTP/2 stream
    def self.from_stream(stream : Stream) : Request
      headers = stream.request_headers || raise Error.new("No request headers")

      # Extract pseudo-headers
      method = nil
      path = nil
      authority = nil
      scheme = nil

      # Create HTTP::Headers from regular headers
      http_headers = HTTP::Headers.new

      headers.each do |name, value|
        case name
        when ":method"
          method = value
        when ":path"
          path = value
        when ":authority"
          authority = value
        when ":scheme"
          scheme = value
        else
          # Regular header
          http_headers[name] = value
        end
      end

      # Validate required pseudo-headers
      method ||= raise Error.new("Missing :method pseudo-header")
      path ||= raise Error.new("Missing :path pseudo-header")
      scheme ||= "https"

      # Set Host header from authority if not present
      if authority && !http_headers.has_key?("host")
        http_headers["host"] = authority
      end

      # Create body IO from stream data
      body = IO::Memory.new(stream.data.to_slice)

      Request.new(method, path, http_headers, body, scheme, authority)
    end

    # Convert to Lucky-compatible request
    def to_lucky_request : HTTP::Request
      # Create HTTP::Request
      request = HTTP::Request.new(
        method: @method,
        resource: @path,
        headers: @headers,
        body: @body.to_s,
        version: @version
      )

      request
    end

    def uri : URI
      URI.parse(@path)
    end

    def query_params : HTTP::Params
      uri.query_params
    end

    def resource : String
      @path
    end

    def body_io : IO
      @body
    end

    def to_s(io : IO) : Nil
      io << @method << " " << @path << " " << @version << "\r\n"
      @headers.each do |name, values|
        values.each do |value|
          io << name << ": " << value << "\r\n"
        end
      end
      io << "\r\n"
      IO.copy(@body, io)
    end
  end
end
