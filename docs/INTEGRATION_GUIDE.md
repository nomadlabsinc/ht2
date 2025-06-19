# HT2 Framework Integration Guide

This guide explains how to integrate HT2's HTTP/2 server with popular Crystal web frameworks.

## Table of Contents

- [Overview](#overview)
- [Core Concepts](#core-concepts)
- [Lucky Framework Integration](#lucky-framework-integration)
- [Kemal Framework Integration](#kemal-framework-integration)
- [Generic HTTP Handler Integration](#generic-http-handler-integration)
- [Advanced Topics](#advanced-topics)
- [Migration from HTTP/1.1](#migration-from-http11)

## Overview

HT2 provides a high-performance HTTP/2 server implementation that can be integrated with any Crystal web framework. The integration follows a simple adapter pattern that converts between HT2's request/response types and your framework's types.

### Key Benefits

- **HTTP/2 Performance**: Multiplexing, server push, header compression
- **Backwards Compatible**: Supports HTTP/1.1 upgrade and h2c
- **Framework Agnostic**: Works with any Crystal HTTP framework
- **Minimal Changes**: Existing applications need minimal modifications

## Core Concepts

### Handler Type

HT2 uses a simple handler type for processing requests:

```crystal
alias Handler = Proc(HT2::Request, HT2::Response, Nil)
```

### Request/Response Types

HT2 provides its own Request and Response types that are compatible with Crystal's standard HTTP types:

```crystal
# HT2::Request provides:
request.method          # HTTP method
request.path           # Request path
request.headers        # Headers
request.body           # Request body
request.to_lucky_request # Convert to HTTP::Request

# HT2::Response provides:
response.status = 200  # Set status code
response.headers       # Response headers
response.write         # Write response body
response.close         # Close the response
```

### Basic Integration Pattern

```crystal
handler = ->(request : HT2::Request, response : HT2::Response) do
  # 1. Convert HT2 request to framework format
  # 2. Process through framework
  # 3. Convert framework response back to HT2
  # 4. Close the response
end

server = HT2::Server.new("localhost", 8080, handler)
server.start
```

## Lucky Framework Integration

Lucky is a full-stack Crystal web framework with strong typing and comprehensive features.

### Step 1: Create an Adapter

Create a file `src/ht2_lucky_adapter.cr`:

```crystal
require "lucky"
require "ht2"

class HT2LuckyAdapter
  def self.handler : HT2::Server::Handler
    ->(request : HT2::Request, response : HT2::Response) do
      # Convert HT2 request to Lucky format
      http_request = request.to_lucky_request
      http_response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(http_request, http_response)

      # Process through Lucky's handler
      Lucky::RouteHandler.new.call(context)
      
      # Convert response back to HT2
      response.status = http_response.status_code
      
      # Copy headers
      http_response.headers.each do |key, values|
        values.each { |value| response.headers[key] = value }
      end
      
      # Copy body
      if body = http_response.output.to_s
        response.write(body.to_slice)
      end
      
      response.close
    rescue ex
      response.status = 500
      response.write("Internal Server Error".to_slice)
      response.close
    end
  end
end
```

### Step 2: Configure Lucky Server

In your Lucky app's `src/server.cr`:

```crystal
require "./app"
require "./ht2_lucky_adapter"
require "ht2"

Habitat.raise_if_missing_settings!

# Create HT2 server with Lucky handler
server = HT2::Server.new(
  host: Lucky::Server.settings.host,
  port: Lucky::Server.settings.port,
  handler: HT2LuckyAdapter.handler
)

puts "Listening on http://#{server.host}:#{server.port}"
server.start
```

### Step 3: Enable TLS (Optional)

For HTTPS with HTTP/2:

```crystal
tls_context = HT2::Server.create_tls_context(
  cert_path: "./config/cert.pem",
  key_path: "./config/key.pem"
)

server = HT2::Server.new(
  host: Lucky::Server.settings.host,
  port: Lucky::Server.settings.port,
  handler: HT2LuckyAdapter.handler,
  tls_context: tls_context
)
```

### Step 4: Server Push Support

Leverage HTTP/2 server push in Lucky actions:

```crystal
class Home::Index < Lucky::Action
  get "/" do
    # Push CSS and JS files before rendering
    if ht2_response = context.response.as?(HT2::Response)
      ht2_response.push_promise("/assets/app.css")
      ht2_response.push_promise("/assets/app.js")
    end
    
    html IndexPage
  end
end
```

## Kemal Framework Integration

Kemal is a fast, simple web framework inspired by Sinatra.

### Step 1: Create an Adapter

Create a file `src/ht2_kemal_adapter.cr`:

```crystal
require "kemal"
require "ht2"

class HT2KemalAdapter
  def self.handler : HT2::Server::Handler
    # Build Kemal's handler chain
    kemal_handlers = Kemal::Config::HANDLERS
    
    ->(request : HT2::Request, response : HT2::Response) do
      # Convert to Kemal format
      http_request = request.to_lucky_request
      http_response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(http_request, http_response)
      
      # Process through Kemal handlers
      kemal_handlers.each { |handler| handler.call(context) }
      
      # Convert back to HT2
      response.status = http_response.status_code
      
      http_response.headers.each do |key, values|
        values.each { |value| response.headers[key] = value }
      end
      
      if body_io = http_response.output.as?(IO::Memory)
        response.write(body_io.to_slice)
      end
      
      response.close
    rescue ex
      response.status = 500
      response.write("Internal Server Error".to_slice)
      response.close
    end
  end
end
```

### Step 2: Configure Kemal Server

In your main application file:

```crystal
require "kemal"
require "./ht2_kemal_adapter"
require "ht2"

# Configure Kemal routes
get "/" do
  "Hello HTTP/2!"
end

get "/api/users" do |env|
  users = [{"id" => 1, "name" => "Alice"}, {"id" => 2, "name" => "Bob"}]
  env.response.content_type = "application/json"
  users.to_json
end

# Don't start Kemal's default server
Kemal.config.serve_static = {"dir_listing" => false, "gzip" => true}
Kemal.setup

# Create and start HT2 server
server = HT2::Server.new(
  host: "0.0.0.0",
  port: 3000,
  handler: HT2KemalAdapter.handler
)

puts "Kemal running on HTTP/2 at http://#{server.host}:#{server.port}"
server.start
```

### Step 3: WebSocket Support

For WebSocket over HTTP/2:

```crystal
ws "/chat" do |socket|
  # WebSocket handling works the same way
  socket.on_message do |message|
    socket.send "Echo: #{message}"
  end
end
```

### Step 4: Static File Serving with Server Push

```crystal
# Custom static handler with HTTP/2 push
class HTTP2StaticHandler < Kemal::Handler
  def call(context)
    if context.request.path == "/" && ht2_res = context.response.as?(HT2::Response)
      # Push static assets
      ht2_res.push_promise("/css/style.css")
      ht2_res.push_promise("/js/app.js")
    end
    
    call_next(context)
  end
end

add_handler HTTP2StaticHandler.new
```

## Generic HTTP Handler Integration

For custom frameworks or direct HTTP handler usage:

### Basic Handler Wrapper

```crystal
require "http/server"
require "ht2"

class HT2HandlerWrapper
  def initialize(@http_handler : HTTP::Handler | HTTP::Handler::HandlerProc)
  end
  
  def to_ht2_handler : HT2::Server::Handler
    ->(request : HT2::Request, response : HT2::Response) do
      # Create HTTP context
      http_request = request.to_lucky_request
      http_response = HTTP::Server::Response.new(IO::Memory.new)
      context = HTTP::Server::Context.new(http_request, http_response)
      
      # Call the HTTP handler
      case handler = @http_handler
      when HTTP::Handler
        handler.call(context)
      when HTTP::Handler::HandlerProc
        handler.call(context)
      end
      
      # Convert response
      response.status = http_response.status_code
      
      http_response.headers.each do |key, values|
        values.each { |value| response.headers[key] = value }
      end
      
      if output = http_response.output.as?(IO::Memory)
        response.write(output.to_slice)
      end
      
      response.close
    end
  end
end
```

### Using the Wrapper

```crystal
# With a simple handler proc
http_handler = ->(context : HTTP::Server::Context) do
  context.response.content_type = "text/plain"
  context.response.print "Hello from HTTP/2!"
end

wrapper = HT2HandlerWrapper.new(http_handler)
server = HT2::Server.new("localhost", 8080, wrapper.to_ht2_handler)
server.start

# With a handler class
class MyHandler
  include HTTP::Handler
  
  def call(context)
    context.response.content_type = "text/html"
    context.response.print "<h1>Welcome to HTTP/2</h1>"
  end
end

wrapper = HT2HandlerWrapper.new(MyHandler.new)
server = HT2::Server.new("localhost", 8080, wrapper.to_ht2_handler)
server.start
```

### Middleware Chain

```crystal
# Build a middleware chain
handlers = [
  HTTP::LogHandler.new,
  HTTP::CompressHandler.new,
  HTTP::StaticFileHandler.new("./public"),
  MyAppHandler.new
]

# Create composite handler
composite_handler = ->(context : HTTP::Server::Context) do
  # Run through handler chain
  handlers.reduce(context) do |ctx, handler|
    handler.call(ctx)
    ctx
  end
end

wrapper = HT2HandlerWrapper.new(composite_handler)
server = HT2::Server.new("localhost", 8080, wrapper.to_ht2_handler)
server.start
```

## Advanced Topics

### Stream Priority

```crystal
handler = ->(request : HT2::Request, response : HT2::Response) do
  # Access stream information
  if stream = request.stream
    priority = stream.priority
    # Use priority for request scheduling
  end
  
  # Handle request...
end
```

### Flow Control

```crystal
handler = ->(request : HT2::Request, response : HT2::Response) do
  # Check if we can write without blocking
  if response.can_write?
    response.write(data)
  else
    # Wait for flow control window
    spawn do
      response.wait_for_write
      response.write(data)
    end
  end
end
```

### Connection Information

```crystal
handler = ->(request : HT2::Request, response : HT2::Response) do
  # Access connection metrics
  if conn = request.connection
    metrics = conn.metrics
    puts "Active streams: #{metrics.current_streams}"
    puts "Total streams: #{metrics.total_streams}"
  end
end
```

### Custom Settings

```crystal
server = HT2::Server.new(
  host: "localhost",
  port: 8080,
  handler: handler,
  max_concurrent_streams: 1000,
  initial_window_size: 1048576,  # 1MB
  max_frame_size: 32768,          # 32KB
  max_header_list_size: 16384     # 16KB
)
```

### H2C (HTTP/2 Clear Text)

For environments behind a reverse proxy:

```crystal
server = HT2::Server.new(
  host: "localhost",
  port: 8080,
  handler: handler,
  enable_h2c: true  # Enable h2c support
)
```

## Migration from HTTP/1.1

### Step 1: Assess Your Application

1. **Review Handler Code**: Ensure handlers don't rely on HTTP/1.1 specific features
2. **Check Middleware**: Verify middleware compatibility with HTTP/2
3. **Update Client Code**: Use HTTP/2 capable clients

### Step 2: Update Configuration

```crystal
# Before (HTTP/1.1)
server = HTTP::Server.new(handler)
server.bind_tcp("localhost", 8080)
server.listen

# After (HTTP/2)
server = HT2::Server.new("localhost", 8080, handler)
server.start
```

### Step 3: Leverage HTTP/2 Features

1. **Server Push**: Push critical resources proactively
2. **Stream Multiplexing**: Handle multiple requests per connection
3. **Header Compression**: Automatic with HPACK
4. **Priority Hints**: Optimize resource delivery

### Step 4: Performance Tuning

```crystal
server = HT2::Server.new(
  host: "localhost",
  port: 8080,
  handler: handler,
  # Performance settings
  max_concurrent_streams: 250,
  initial_window_size: 2097152,  # 2MB for high throughput
  enable_push: true,
  # Connection pooling
  max_connections: 10000,
  connection_timeout: 30.seconds
)
```

### Common Pitfalls

1. **Header Restrictions**: HTTP/2 requires lowercase header names
2. **Connection Handling**: One connection handles multiple streams
3. **Protocol Detection**: Use ALPN for TLS, upgrade for clear text
4. **Flow Control**: Respect flow control windows to avoid deadlocks

### Testing Your Integration

```bash
# Test with curl
curl --http2 https://localhost:8080/

# Test h2c (clear text)
curl --http2-prior-knowledge http://localhost:8080/

# Load test with h2load
h2load -n 10000 -c 100 -m 10 https://localhost:8080/
```

## Next Steps

- Review the [API Reference](API_REFERENCE.md) for detailed documentation
- Check out [examples](../examples/) for working code samples
- Read about [Performance Tuning](API_REFERENCE.md#performance-tuning) for optimization tips
- Join our community for support and updates

For framework-specific questions, please refer to each framework's documentation and community resources.