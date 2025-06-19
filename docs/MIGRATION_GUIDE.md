# Migration Guide: From Crystal's HTTP::Server to HT2

This guide helps you migrate existing applications from Crystal's built-in `HTTP::Server` to HT2's HTTP/2 server, enabling modern protocol features while maintaining compatibility with your existing code.

## Table of Contents

1. [Why Migrate to HT2?](#why-migrate-to-ht2)
2. [Basic Migration](#basic-migration)
3. [Handler Migration](#handler-migration)
4. [Middleware Migration](#middleware-migration)
5. [Request/Response Differences](#requestresponse-differences)
6. [WebSocket Migration](#websocket-migration)
7. [Configuration Changes](#configuration-changes)
8. [Performance Considerations](#performance-considerations)
9. [Common Pitfalls](#common-pitfalls)
10. [Gradual Migration Strategy](#gradual-migration-strategy)

## Why Migrate to HT2?

HT2 provides significant advantages over Crystal's HTTP/1.1 server:

- **HTTP/2 Support**: Multiplexing, server push, header compression
- **Better Performance**: Connection pooling, zero-copy operations, adaptive flow control
- **Enhanced Security**: Built-in protection against HTTP/2-specific attacks
- **Modern Features**: Stream priorities, efficient binary framing
- **Backward Compatibility**: Still supports HTTP/1.1 clients via ALPN

## Basic Migration

### Crystal HTTP::Server (Before)

```crystal
require "http/server"

server = HTTP::Server.new do |context|
  context.response.content_type = "text/plain"
  context.response.print "Hello, World!"
end

server.bind_tcp("127.0.0.1", 8080)
server.listen
```

### HT2 Server (After)

```crystal
require "ht2"

handler = HT2::Handler.new do |request|
  HT2::Response.new(
    body: "Hello, World!",
    headers: {"content-type" => "text/plain"},
    status: 200
  )
end

server = HT2::Server.new(
  handler: handler,
  host: "127.0.0.1",
  port: 8080
)

server.listen
```

## Handler Migration

### Simple Handler

**Crystal HTTP::Server:**
```crystal
class MyHandler
  include HTTP::Handler
  
  def call(context)
    case context.request.path
    when "/"
      context.response.print "Home"
    when "/about"
      context.response.print "About"
    else
      context.response.status = HTTP::Status::NOT_FOUND
      context.response.print "Not Found"
    end
  end
end
```

**HT2:**
```crystal
class MyHandler < HT2::Handler
  def handle(request : HT2::Request) : HT2::Response
    case request.path
    when "/"
      HT2::Response.new(body: "Home")
    when "/about"
      HT2::Response.new(body: "About")
    else
      HT2::Response.new(body: "Not Found", status: 404)
    end
  end
end
```

### Handler with Middleware Chain

**Crystal HTTP::Server:**
```crystal
server = HTTP::Server.new([
  HTTP::LogHandler.new,
  HTTP::CompressHandler.new,
  MyHandler.new,
])
```

**HT2:**
```crystal
# Create a composite handler
composite_handler = HT2::Handler.new do |request|
  # Log request
  Log.info { "#{request.method} #{request.path}" }
  
  # Process with main handler
  response = MyHandler.new.handle(request)
  
  # Apply compression if supported
  if request.headers["accept-encoding"]?.try(&.includes?("gzip"))
    response.headers["content-encoding"] = "gzip"
    # Apply gzip compression to response.body
  end
  
  response
end

server = HT2::Server.new(handler: composite_handler)
```

## Middleware Migration

### Creating HT2-Compatible Middleware

```crystal
# Base middleware class
abstract class HT2::Middleware < HT2::Handler
  def initialize(@next : HT2::Handler)
  end
  
  abstract def process(request : HT2::Request, next_handler : HT2::Handler) : HT2::Response
  
  def handle(request : HT2::Request) : HT2::Response
    process(request, @next)
  end
end

# Example: Logging middleware
class LoggingMiddleware < HT2::Middleware
  def process(request : HT2::Request, next_handler : HT2::Handler) : HT2::Response
    start_time = Time.monotonic
    
    response = next_handler.handle(request)
    
    duration = Time.monotonic - start_time
    Log.info { "#{request.method} #{request.path} - #{response.status} (#{duration.total_milliseconds}ms)" }
    
    response
  end
end

# Example: Authentication middleware
class AuthMiddleware < HT2::Middleware
  def process(request : HT2::Request, next_handler : HT2::Handler) : HT2::Response
    auth_header = request.headers["authorization"]?
    
    unless auth_header && valid_token?(auth_header)
      return HT2::Response.new(
        body: "Unauthorized",
        headers: {"www-authenticate" => "Bearer realm=\"api\""},
        status: 401
      )
    end
    
    next_handler.handle(request)
  end
  
  private def valid_token?(auth_header : String) : Bool
    # Token validation logic
    true
  end
end

# Chain middleware
app_handler = MyHandler.new
auth_handler = AuthMiddleware.new(app_handler)
log_handler = LoggingMiddleware.new(auth_handler)

server = HT2::Server.new(handler: log_handler)
```

## Request/Response Differences

### Request Object

| Crystal HTTP::Server | HT2 | Notes |
|---------------------|-----|-------|
| `context.request.method` | `request.method` | Same format |
| `context.request.path` | `request.path` | Same format |
| `context.request.headers` | `request.headers` | Case-insensitive in HT2 |
| `context.request.body` | `request.body` | Returns IO in both |
| `context.request.query_params` | `request.query_params` | Same format |
| `context.request.cookies` | `request.cookies` | Same format |

### Response Object

| Crystal HTTP::Server | HT2 | Notes |
|---------------------|-----|-------|
| `context.response.status = 200` | `HT2::Response.new(status: 200)` | Immutable in HT2 |
| `context.response.headers["key"] = "value"` | Pass headers to constructor | Headers set at creation |
| `context.response.print "text"` | `HT2::Response.new(body: "text")` | Body set at creation |
| `context.response.content_type = "..."` | Include in headers hash | No special setter |

### Streaming Responses

**Crystal HTTP::Server:**
```crystal
context.response.headers["Transfer-Encoding"] = "chunked"
context.response.print "First chunk"
context.response.flush
sleep 1
context.response.print "Second chunk"
```

**HT2:**
```crystal
# Use body_io for streaming
io = IO::Memory.new
spawn do
  io.print "First chunk"
  io.flush
  sleep 1
  io.print "Second chunk"
  io.close
end

HT2::Response.new(
  body_io: io,
  headers: {"content-type" => "text/plain"}
)
```

## WebSocket Migration

### Crystal HTTP::Server WebSocket

```crystal
ws_handler = HTTP::WebSocketHandler.new do |ws, ctx|
  ws.on_message do |message|
    ws.send "Echo: #{message}"
  end
end

server = HTTP::Server.new([ws_handler, http_handler])
```

### HT2 WebSocket over HTTP/2

```crystal
class WSHandler < HT2::Handler
  def handle(request : HT2::Request) : HT2::Response
    if request.path == "/ws" && websocket_upgrade?(request)
      # WebSocket over HTTP/2 uses CONNECT method
      return handle_websocket(request)
    end
    
    # Regular HTTP handling
    HT2::Response.new(body: "Not a WebSocket request", status: 400)
  end
  
  private def websocket_upgrade?(request : HT2::Request) : Bool
    request.headers["upgrade"]? == "websocket" ||
    (request.method == "CONNECT" && request.headers[":protocol"]? == "websocket")
  end
  
  private def handle_websocket(request : HT2::Request) : HT2::Response
    # Return 200 OK to establish WebSocket
    # The stream will be used for WebSocket frames
    HT2::Response.new(
      headers: {":status" => "200"},
      status: 200
    )
  end
end
```

## Configuration Changes

### TLS Configuration

**Crystal HTTP::Server:**
```crystal
context = OpenSSL::SSL::Context::Server.new
context.certificate_chain = "cert.pem"
context.private_key = "key.pem"

server = HTTP::Server.new(handler)
server.bind_tls("0.0.0.0", 443, context)
```

**HT2:**
```crystal
tls_context = OpenSSL::SSL::Context::Server.new
tls_context.certificate_chain = "cert.pem"
tls_context.private_key = "key.pem"
# HT2 automatically configures ALPN for HTTP/2
tls_context.alpn_protocol = "h2"

server = HT2::Server.new(
  handler: handler,
  host: "0.0.0.0",
  port: 443,
  tls: tls_context
)
```

### Server Options

```crystal
# HT2 provides many HTTP/2-specific options
server = HT2::Server.new(
  handler: handler,
  host: "127.0.0.1",
  port: 8080,
  
  # HTTP/2 specific settings
  enable_push: true,           # Server push support
  initial_window_size: 65535,  # Flow control window
  max_concurrent_streams: 100, # Concurrent streams per connection
  max_frame_size: 16384,       # Maximum frame size
  max_header_list_size: 8192,  # Maximum header size
  
  # Performance settings
  read_timeout: 30.seconds,
  write_timeout: 30.seconds,
  
  # h2c (HTTP/2 cleartext) support
  enable_h2c: true  # For proxy deployments
)
```

## Performance Considerations

### Connection Reuse

HT2 automatically handles connection multiplexing. Update your client code to reuse connections:

```crystal
# Create a client instance and reuse it
client = HT2::Client.new
responses = 100.times.map do |i|
  client.get("https://example.com/api/item/#{i}")
end
```

### Server Push

Take advantage of server push for related resources:

```crystal
class AssetHandler < HT2::Handler
  def handle(request : HT2::Request) : HT2::Response
    if request.path == "/index.html"
      # Push CSS and JS files proactively
      if request.server_push_enabled?
        request.push_promise("/style.css", {
          ":method" => "GET",
          ":path" => "/style.css"
        })
        request.push_promise("/app.js", {
          ":method" => "GET",
          ":path" => "/app.js"
        })
      end
      
      HT2::Response.new(
        body: File.read("public/index.html"),
        headers: {"content-type" => "text/html"}
      )
    else
      # Handle other resources
    end
  end
end
```

### Flow Control

HT2 includes adaptive flow control. Monitor backpressure:

```crystal
# Access connection metrics
server.on_connection do |connection|
  spawn do
    loop do
      metrics = connection.metrics
      if metrics.backpressure_level > 0.9
        Log.warn { "High backpressure: #{metrics.backpressure_level}" }
      end
      sleep 10.seconds
    end
  end
end
```

## Common Pitfalls

### 1. Header Case Sensitivity

HTTP/2 headers are lowercase. Update header access:

```crystal
# Crystal HTTP::Server (case-insensitive but preserves case)
auth = context.request.headers["Authorization"]?

# HT2 (always lowercase)
auth = request.headers["authorization"]?
```

### 2. Response Mutability

HT2 responses are immutable. Build complete responses:

```crystal
# Won't work - responses are immutable
response = HT2::Response.new(body: "Hello")
response.headers["x-custom"] = "value"  # Error!

# Correct approach
response = HT2::Response.new(
  body: "Hello",
  headers: {"x-custom" => "value"}
)
```

### 3. Connection Limits

HTTP/2 has different connection patterns:

```crystal
# HTTP/1.1 servers often limit connections
# HTTP/2 uses fewer connections with more streams

server = HT2::Server.new(
  handler: handler,
  max_concurrent_streams: 1000  # Per connection
)
```

### 4. Request Body Handling

HTTP/2 streams data differently:

```crystal
# Ensure you handle streaming bodies
def handle(request : HT2::Request) : HT2::Response
  if request.headers["content-length"]?
    # Known size - can read all at once
    body = request.body.gets_to_end
  else
    # Streaming body - process in chunks
    buffer = IO::Memory.new
    IO.copy(request.body, buffer)
    body = buffer.to_s
  end
  
  # Process body...
end
```

## Gradual Migration Strategy

### 1. Run Both Servers (Transition Period)

```crystal
# Run HT2 on a different port initially
spawn do
  ht2_server = HT2::Server.new(
    handler: adapter,
    port: 8081  # Different port
  )
  ht2_server.listen
end

# Keep existing HTTP/1.1 server
http_server = HTTP::Server.new(old_handler)
http_server.bind_tcp(8080)
http_server.listen
```

### 2. Use a Load Balancer

Configure your load balancer to gradually shift traffic:

```nginx
upstream http1_backend {
    server 127.0.0.1:8080;
}

upstream http2_backend {
    server 127.0.0.1:8081;
}

server {
    listen 443 ssl http2;
    
    # Route based on percentage
    location / {
        # 10% to HTTP/2 initially
        if ($random_0_9 = 0) {
            proxy_pass https://http2_backend;
            break;
        }
        proxy_pass https://http1_backend;
    }
}
```

### 3. Feature Flag Approach

```crystal
class MigrationHandler < HT2::Handler
  def initialize(@legacy_handler : HTTP::Handler, @ht2_handler : HT2::Handler)
  end
  
  def handle(request : HT2::Request) : HT2::Response
    if use_legacy_handler?(request)
      # Adapt legacy handler response
      adapt_legacy_response(@legacy_handler.call(adapt_request(request)))
    else
      @ht2_handler.handle(request)
    end
  end
  
  private def use_legacy_handler?(request : HT2::Request) : Bool
    # Decision logic: feature flags, paths, headers, etc.
    request.headers["x-use-legacy"]? == "true"
  end
end
```

### 4. Monitor and Compare

Track metrics during migration:

```crystal
class MetricsHandler < HT2::Middleware
  def process(request : HT2::Request, next_handler : HT2::Handler) : HT2::Response
    start = Time.monotonic
    response = next_handler.handle(request)
    duration = Time.monotonic - start
    
    # Track HT2 performance
    Metrics.record("ht2.request.duration", duration.total_milliseconds)
    Metrics.increment("ht2.request.count")
    
    response
  end
end
```

## Testing Your Migration

### 1. Protocol Compatibility Test

```crystal
# Test both HTTP/1.1 and HTTP/2 clients
require "spec"

describe "Protocol Compatibility" do
  it "handles HTTP/1.1 requests" do
    response = HTTP::Client.get("https://localhost:8443/")
    response.status_code.should eq(200)
  end
  
  it "handles HTTP/2 requests" do
    client = HT2::Client.new
    response = client.get("https://localhost:8443/")
    response.status.should eq(200)
  end
end
```

### 2. Load Testing

```bash
# Test with h2load for HTTP/2 performance
h2load -n10000 -c100 -m10 https://localhost:8443/

# Compare with HTTP/1.1
h2load --h1 -n10000 -c100 https://localhost:8443/
```

### 3. Feature Testing

```crystal
# Test HTTP/2 specific features
describe "HTTP/2 Features" do
  it "supports server push" do
    client = HT2::Client.new
    pushed_resources = [] of String
    
    client.on_push_promise do |path, headers|
      pushed_resources << path
    end
    
    response = client.get("https://localhost:8443/index.html")
    pushed_resources.should contain("/style.css")
    pushed_resources.should contain("/app.js")
  end
end
```

## Conclusion

Migrating from Crystal's HTTP::Server to HT2 provides significant benefits in performance, security, and modern protocol support. The migration can be done gradually, allowing you to test and validate at each step. Focus on:

1. Starting with a simple handler adapter
2. Gradually migrating middleware
3. Taking advantage of HTTP/2 features
4. Monitoring performance improvements
5. Running both servers during transition

For more details, see the [HT2 API Reference](./API_REFERENCE.md) and [Integration Guide](./INTEGRATION_GUIDE.md).