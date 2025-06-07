require "http"

module HT2
  class Response
    getter stream : Stream
    getter headers : HTTP::Headers
    getter status : Int32
    getter? closed : Bool

    @headers_sent : Bool
    @body : IO::Memory

    def initialize(@stream : Stream)
      @headers = HTTP::Headers.new
      @status = 200
      @closed = false
      @headers_sent = false
      @body = IO::Memory.new
    end

    def status=(@status : Int32)
      raise Error.new("Cannot change status after headers sent") if @headers_sent
    end

    def headers=(@headers : HTTP::Headers)
      raise Error.new("Cannot change headers after headers sent") if @headers_sent
    end

    def write(data : String) : Nil
      write(data.to_slice)
    end

    def write(data : Bytes) : Nil
      raise Error.new("Cannot write to closed response") if @closed

      unless @headers_sent
        send_headers(end_stream: false)
      end

      @body.write(data)
    end

    def close : Nil
      return if @closed
      @closed = true

      if @headers_sent
        # Send any remaining body data
        body_data = @body.to_slice
        if body_data.size > 0
          @stream.send_data(body_data, end_stream: true)
        else
          # Send empty DATA frame with END_STREAM
          @stream.send_data(Bytes.empty, end_stream: true)
        end
      else
        # Send headers with END_STREAM
        send_headers(end_stream: true)
      end
    end

    # Convert from Lucky::Response if needed
    def self.from_lucky_response(stream : Stream, lucky_response : HTTP::Server::Response) : Response
      response = Response.new(stream)
      response.status = lucky_response.status_code

      # Copy headers
      lucky_response.headers.each do |name, values|
        values.each do |value|
          response.headers[name] = value
        end
      end

      # Copy body if any
      if body = lucky_response.@output
        body.rewind
        IO.copy(body, response)
      end

      response
    end

    private def send_headers(end_stream : Bool)
      return if @headers_sent
      @headers_sent = true

      # Build header list with pseudo-headers first
      header_list = Array(Tuple(String, String)).new

      # Add status pseudo-header
      header_list << {":status", @status.to_s}

      # Add regular headers
      @headers.each do |name, values|
        # Skip connection-specific headers
        next if connection_specific_header?(name)

        values.each do |value|
          header_list << {name.downcase, value}
        end
      end

      # Set default headers if not present
      unless @headers.has_key?("content-type")
        header_list << {"content-type", "text/plain"}
      end

      # Send HEADERS frame
      if end_stream && @body.size == 0
        @stream.send_headers(header_list, end_stream: true)
      else
        @stream.send_headers(header_list, end_stream: false)

        # Send body data if we're closing
        if end_stream
          body_data = @body.to_slice
          @stream.send_data(body_data, end_stream: true)
        end
      end
    end

    private def connection_specific_header?(name : String) : Bool
      case name.downcase
      when "connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade"
        true
      else
        false
      end
    end

    def to_s(io : IO) : Nil
      io << "HTTP/2 " << @status << " " << HTTP::Status.new(@status).description << "\r\n"
      @headers.each do |name, values|
        values.each do |value|
          io << name << ": " << value << "\r\n"
        end
      end
      io << "\r\n"
      io.write(@body.to_slice)
    end
  end
end
