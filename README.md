# HT2

HTTP/2 server implementation for Crystal, designed for integration with the Lucky framework and other Crystal web frameworks.

## Features

- Full HTTP/2 protocol implementation (RFC 7540)
- HPACK header compression (RFC 7541)
- TLS with ALPN negotiation
- Stream multiplexing and flow control
- Priority handling
- Server push support (framework)
- Integration with Lucky, Kemal, Marten, and other Crystal frameworks

## Installation

Add this to your application's `shard.yml`:

```yaml
dependencies:
  ht2:
    github: nomadlabsinc/ht2
    branch: main
```

## Usage

### Basic HTTP/2 Server

```crystal
require "ht2"

# Create handler
handler = ->(request : HT2::Request, response : HT2::Response) do
  response.status = 200
  response.headers["content-type"] = "text/plain"
  response.write("Hello, HTTP/2!")
  response.close
end

# Create TLS context (required for HTTP/2)
tls_context = HT2::Server.create_tls_context("cert.pem", "key.pem")

# Create and start server
server = HT2::Server.new("localhost", 8443, handler, tls_context)
server.listen
```

### Integration with Lucky Framework

The Lucky framework integration requires creating an adapter that bridges Lucky's request/response with HTTP/2:

```crystal
# In config/server.cr
require "ht2"

class Lucky::Server::HTTP2Adapter
  getter host : String
  getter port : Int32
  getter handler : HTTP::Handler
  
  def initialize(@host : String, @port : Int32, @handler : HTTP::Handler)
    @server = nil
  end
  
  def listen : Nil
    tls_context = HT2::Server.create_tls_context(
      Lucky::Server.settings.ssl_cert_file,
      Lucky::Server.settings.ssl_key_file
    )
    
    handler = ->(request : HT2::Request, response : HT2::Response) do
      # Convert to Lucky-compatible context
      http_request = request.to_lucky_request
      http_response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(http_request, http_response)
      
      # Process through Lucky's handler chain
      @handler.call(context)
      
      # Convert response back to HTTP/2
      response.status = http_response.status_code
      http_response.headers.each do |name, values|
        values.each { |value| response.headers[name] = value }
      end
      
      if body_io = http_response.@output
        body_io.rewind
        response.write(body_io.gets_to_end.to_slice)
      end
      
      response.close
    end
    
    @server = server = HT2::Server.new(@host, @port, handler, tls_context)
    server.listen
  end
  
  def close : Nil
    @server.try(&.close)
  end
end

# In Lucky startup
if Lucky::Env.production? && Lucky::Server.settings.http2_enabled
  server = Lucky::Server::HTTP2Adapter.new(
    Lucky::Server.settings.host,
    Lucky::Server.settings.port,
    Lucky::Server.build_handler
  )
  server.listen
end
```

### Integration with Kemal

Kemal integration is straightforward since it uses standard HTTP handlers:

```crystal
require "kemal"
require "ht2"

# Define your Kemal routes as usual
get "/" do
  "Hello from Kemal over HTTP/2!"
end

post "/api/data" do |env|
  data = env.params.json["data"]?
  {"received" => data}.to_json
end

# Create HTTP/2 server with Kemal handler
handler = ->(request : HT2::Request, response : HT2::Response) do
  # Convert to Kemal-compatible request
  http_request = request.to_lucky_request
  http_response = HTTP::Server::Response.new(IO::Memory.new)
  context = HTTP::Server::Context.new(http_request, http_response)
  
  # Process through Kemal
  Kemal.config.handlers.each { |handler| handler.call(context) }
  
  # Convert response back
  response.status = http_response.status_code
  http_response.headers.each do |name, values|
    values.each { |value| response.headers[name] = value }
  end
  
  if body_io = http_response.@output
    body_io.rewind
    response.write(body_io.gets_to_end.to_slice)
  end
  
  response.close
end

# Create TLS context
tls_context = HT2::Server.create_tls_context("cert.pem", "key.pem")

# Start HTTP/2 server
server = HT2::Server.new("localhost", 8443, handler, tls_context)

puts "Kemal running over HTTP/2 on https://localhost:8443"
server.listen
```

### Integration with Marten

Marten integration follows a similar pattern:

```crystal
require "marten"
require "ht2"

# Configure Marten as usual
Marten.configure do |config|
  config.secret_key = "your-secret-key"
  # ... other configuration
end

# Set up Marten routes
Marten.routes.draw do
  path "/", HomeHandler, name: "home"
  path "/api", ApiHandler, name: "api"
end

# Create HTTP/2 handler for Marten
handler = ->(request : HT2::Request, response : HT2::Response) do
  # Convert to Marten-compatible request
  http_request = request.to_lucky_request
  
  # Create Marten request object
  marten_request = Marten::HTTP::Request.new(http_request)
  
  # Get Marten response
  marten_response = Marten.handlers.handle(marten_request)
  
  # Convert response back to HTTP/2
  response.status = marten_response.status
  marten_response.headers.each do |name, value|
    response.headers[name] = value
  end
  
  response.write(marten_response.content.to_slice)
  response.close
end

# Create TLS context
tls_context = HT2::Server.create_tls_context("cert.pem", "key.pem")

# Start server
server = HT2::Server.new("localhost", 8443, handler, tls_context)
puts "Marten running over HTTP/2 on https://localhost:8443"
server.listen
```

### Generic Framework Adapter

For any Crystal web framework that uses `HTTP::Server::Context`, you can use this generic adapter:

```crystal
require "ht2"

class HTTP2Adapter
  def self.create_handler(framework_handler : HTTP::Handler) : HT2::Server::Handler
    ->(request : HT2::Request, response : HT2::Response) do
      # Convert HTTP/2 request to standard HTTP request
      http_request = request.to_lucky_request
      http_response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(http_request, http_response)
      
      # Process through framework
      framework_handler.call(context)
      
      # Convert response back to HTTP/2
      response.status = http_response.status_code
      http_response.headers.each do |name, values|
        values.each { |value| response.headers[name] = value }
      end
      
      if body_io = http_response.@output
        body_io.rewind
        response.write(body_io.gets_to_end.to_slice)
      end
      
      response.close
    end
  end
end

# Usage with any framework
framework_handler = YourFramework.build_handler
http2_handler = HTTP2Adapter.create_handler(framework_handler)

tls_context = HT2::Server.create_tls_context("cert.pem", "key.pem")
server = HT2::Server.new("localhost", 8443, http2_handler, tls_context)
server.listen
```

## TLS Certificate Generation

For development, you can generate a self-signed certificate:

```bash
# Generate private key
openssl genpkey -algorithm RSA -out key.pem -pkeyopt rsa_keygen_bits:2048

# Generate certificate
openssl req -new -x509 -key key.pem -out cert.pem -days 365 \
  -subj "/CN=localhost"
```

For production, use certificates from Let's Encrypt or your CA.

## Configuration Options

```crystal
server = HT2::Server.new(
  host: "localhost",
  port: 8443,
  handler: handler,
  tls_context: tls_context,
  max_concurrent_streams: 100,    # Max streams per connection
  initial_window_size: 65535,     # Flow control window
  max_frame_size: 16384,          # Max frame size
  max_header_list_size: 8192      # Max header list size
)
```

## Performance Considerations

1. **Connection Pooling**: HTTP/2 multiplexes streams over a single connection, reducing overhead
2. **Header Compression**: HPACK reduces header size significantly
3. **Binary Protocol**: More efficient parsing than HTTP/1.1
4. **Stream Prioritization**: Better resource allocation

## Testing

Run the test suite:

```bash
crystal spec
```

Run with verbose output:

```bash
crystal spec --verbose
```

## Benchmarks

The shard includes benchmarks comparing HTTP/1.1 and HTTP/2:

```bash
crystal run benchmarks/server_benchmark.cr --release
```

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## License

MIT License - see LICENSE file for details
