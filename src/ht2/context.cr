module HT2
  # Context provides a convenient wrapper for request/response handling
  class Context
    getter request : Request
    getter response : Response

    def initialize(@request : Request, @response : Response)
    end

    # Convert to HTTP::Server::Context for Lucky compatibility
    def to_http_context : HTTP::Server::Context
      # Create HTTP request
      http_request = @request.to_lucky_request

      # Create HTTP response
      http_response = HTTP::Server::Response.new(IO::Memory.new)
      http_response.status_code = @response.status

      # Copy headers
      @response.headers.each do |name, value|
        http_response.headers[name] = value
      end

      HTTP::Server::Context.new(http_request, http_response)
    end

    def self.from_stream(stream : Stream) : Context
      request = Request.from_stream(stream)
      response = Response.new(stream)
      Context.new(request, response)
    end
  end
end
