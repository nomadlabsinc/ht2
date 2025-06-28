# HT2 API Reference

## Table of Contents

- [Overview](#overview)
- [Installation](#installation)
- [Basic Usage](#basic-usage)
- [Server API](#server-api)
- [Request & Response](#request--response)
- [Error Handling](#error-handling)
- [Advanced Features](#advanced-features)
- [Performance Tuning](#performance-tuning)
- [Monitoring & Metrics](#monitoring--metrics)

## Overview

HT2 is a high-performance HTTP/2 server implementation for Crystal, designed for building fast and secure web servers.

### Key Features
- Full HTTP/2 protocol support (RFC 9113)
- Built-in security features (CVE-2023-44487 protection)
- HPACK header compression
- Stream multiplexing
- Server push support
- Adaptive flow control
- Zero-copy optimizations
- H2C (HTTP/2 cleartext) support

## Installation

Add HT2 to your `shard.yml`:

```yaml
dependencies:
  ht2:
    github: nomadlabsinc/ht2
    branch: main
```

Then run:
```bash
shards install
```

## Basic Usage

### Simple HTTP/2 Server

```crystal
require "ht2"

# Create a server with a simple handler
handler = ->(request : HT2::Request, response : HT2::Response) do
  response.headers["content-type"] = "text/plain"
  response.write("Hello, HTTP/2!".to_slice)
  response.close
end

# Create TLS context (required for HTTP/2)
tls_context = HT2::Server.create_tls_context("cert.pem", "key.pem")

# Create and start server
server = HT2::Server.new("localhost", 8443, handler, tls_context)
server.listen
```

## Server API

### HT2::Server

The main server class for handling HTTP/2 connections.

#### Constructor

```crystal
def initialize(
  handler : Handler,
  worker_pool_size : Int32 = 32,
  max_concurrent_streams : UInt32 = 1000,
  initial_window_size : UInt32 = 65535,
  max_frame_size : UInt32 = 16384,
  max_header_list_size : UInt32 = 8192,
  idle_timeout : Time::Span = 120.seconds,
  rapid_reset_threshold : Float64 = 0.5,
  rapid_reset_window : Time::Span = 10.seconds
)
```

**Parameters:**
- `handler`: Request handler function `Proc(Request, Response, Nil)`
- `worker_pool_size`: Number of worker fibers for processing requests (default: 32)
- `max_concurrent_streams`: Maximum concurrent streams per connection (default: 1000)
- `initial_window_size`: Initial flow control window size (default: 65535)
- `max_frame_size`: Maximum frame size in bytes (default: 16384)
- `max_header_list_size`: Maximum header list size in bytes (default: 8192)
- `idle_timeout`: Connection idle timeout (default: 120 seconds)
- `rapid_reset_threshold`: Threshold for rapid reset attack detection (default: 0.5)
- `rapid_reset_window`: Time window for rapid reset detection (default: 10 seconds)

#### Methods

##### `#listen(host : String, port : Int32, reuse_port : Bool = false, tls : OpenSSL::SSL::Context::Server? = nil) : Nil`

Start the server and listen for connections.

**Parameters:**
- `host`: Bind address (e.g., "0.0.0.0", "::1")
- `port`: Port number
- `reuse_port`: Enable SO_REUSEPORT for load balancing (default: false)
- `tls`: TLS context for HTTPS (required for HTTP/2)

**Example:**
```crystal
# Listen with TLS
tls_context = HT2::Server.create_tls_context("cert.pem", "key.pem")
server.listen("0.0.0.0", 8443, tls: tls_context)

# Listen with custom TLS configuration
tls_context = OpenSSL::SSL::Context::Server.new
tls_context.certificate_chain = "fullchain.pem"
tls_context.private_key = "privkey.pem"
tls_context.alpn_protocol = "h2"
server.listen("0.0.0.0", 8443, tls: tls_context)
```

##### `#close : Nil`

Gracefully shutdown the server.

```crystal
server.close
```

##### `#worker_pool_active_count : Int32`

Get the number of active workers.

```crystal
active_workers = server.worker_pool_active_count
puts "Active workers: #{active_workers}"
```

##### `#worker_pool_queue_depth : Int32`

Get the current queue depth.

```crystal
queue_depth = server.worker_pool_queue_depth
puts "Queued requests: #{queue_depth}"
```

##### `.create_tls_context(cert_path : String, key_path : String) : OpenSSL::SSL::Context::Server`

Helper method to create a TLS context configured for HTTP/2.

**Parameters:**
- `cert_path`: Path to certificate file
- `key_path`: Path to private key file

**Returns:** Configured TLS context with HTTP/2 ALPN

**Example:**
```crystal
tls = HT2::Server.create_tls_context("/path/to/cert.pem", "/path/to/key.pem")
```

### Handler Type

```crystal
alias Handler = Proc(Request, Response, Nil)
```

The handler is a proc that receives a request and response object.

**Example Handlers:**

```crystal
# Simple handler
handler = ->(request : HT2::Request, response : HT2::Response) {
  response.headers["content-type"] = "text/plain"
  response.write("Hello!".to_slice)
  response.close
}

# JSON API handler
api_handler = ->(request : HT2::Request, response : HT2::Response) {
  case request.path
  when "/api/users"
    response.headers["content-type"] = "application/json"
    response.write({"users" => ["alice", "bob"]}.to_json.to_slice)
  else
    response.status = 404
    response.write("Not Found".to_slice)
  end
  response.close
}

# File server with server push
file_handler = ->(request : HT2::Request, response : HT2::Response) {
  if request.path == "/index.html"
    # Push CSS file before sending HTML
    response.stream.push_promise("/style.css", HTTP::Headers{
      ":method" => "GET",
      ":path" => "/style.css"
    })
    
    response.headers["content-type"] = "text/html"
    response.write(File.read("index.html").to_slice)
  end
  response.close
}
```

## Request & Response

### HT2::Request

Represents an HTTP/2 request.

#### Properties

- `method : String` - HTTP method (GET, POST, etc.)
- `path : String` - Request path
- `authority : String` - Host authority
- `scheme : String` - URL scheme (http/https)
- `headers : HTTP::Headers` - Request headers
- `body : IO?` - Request body stream
- `version : String` - HTTP version

#### Methods

##### `#uri : URI`

Get the full URI of the request.

```crystal
uri = request.uri
puts uri.to_s # => "https://example.com/path"
```

##### `#query_params : URI::Params`

Get parsed query parameters.

```crystal
# For request to /search?q=crystal&limit=10
params = request.query_params
puts params["q"]     # => "crystal"
puts params["limit"] # => "10"
```

### HT2::Response

Represents an HTTP/2 response.

#### Properties

- `stream : Stream` - Underlying HTTP/2 stream
- `headers : HTTP::Headers` - Response headers
- `status : Int32` - HTTP status code (default: 200)
- `closed? : Bool` - Whether response is closed

#### Methods

##### `#write(data : Bytes) : Nil`

Write data to the response body.

**Parameters:**
- `data`: Bytes to write

**Example:**
```crystal
response.write("Hello, World!".to_slice)
response.write(File.read("image.png").to_slice)
```

##### `#close : Nil`

Close the response stream.

```crystal
response.close
```

## Error Handling

### Error Types

HT2 provides specific error types for different scenarios:

```crystal
module HT2::Errors
  # Connection-level errors
  class ConnectionError < Exception
  class ProtocolError < ConnectionError
  class GoawayError < ConnectionError
  
  # Stream-level errors
  class StreamError < Exception
  class StreamClosedError < StreamError
  
  # Flow control errors
  class FlowControlError < Exception
  
  # Compression errors
  class CompressionError < Exception
  
  # Frame errors
  class FrameSizeError < Exception
  
  # Security errors
  class SecurityError < Exception
  class RapidResetAttack < SecurityError
end
```

### Error Handling Examples

```crystal
# Server error handling
server = HT2::Server.new(handler: ->(request, response) {
  begin
    # Process request
    case request.path
    when "/api/data"
      data = fetch_data()
      response.write(data.to_json.to_slice)
    else
      response.status = 404
      response.write("Not Found".to_slice)
    end
  rescue ex : DatabaseError
    response.status = 500
    response.write("Internal Server Error".to_slice)
    Log.error { "Database error: #{ex.message}" }
  ensure
    response.close
  end
})

# Server error handling with connection issues
begin
  # In a server handler when issues occur
  if connection_error_detected
    raise HT2::Errors::ConnectionError.new("Connection lost")
  end
rescue ex : HT2::Errors::ConnectionError
  Log.error { "Connection failed: #{ex.message}" }
  # Handle connection cleanup
rescue ex : HT2::Errors::GoawayError
  Log.warn { "Server sent GOAWAY: #{ex.message}" }
  # Graceful shutdown
rescue ex : HT2::Errors::SecurityError
  Log.error { "Security violation: #{ex.message}" }
  # Alert security team
end
```

## Advanced Features

### Server Push

HTTP/2 server push allows sending resources proactively.

```crystal
handler = ->(request : HT2::Request, response : HT2::Response) {
  if request.path == "/index.html"
    # Push CSS and JS files
    response.stream.push_promise("/style.css", HTTP::Headers{
      ":method" => "GET",
      ":path" => "/style.css",
      ":authority" => request.authority,
      ":scheme" => request.scheme
    })
    
    response.stream.push_promise("/app.js", HTTP::Headers{
      ":method" => "GET",
      ":path" => "/app.js",
      ":authority" => request.authority,
      ":scheme" => request.scheme
    })
    
    # Send the HTML
    response.headers["content-type"] = "text/html"
    response.write(render_html.to_slice)
  end
  response.close
}
```

### Stream Priority

Control stream processing order:

```crystal
# In a custom connection handler
connection.on_headers = ->(stream, headers, end_stream) {
  # Set high priority for API endpoints
  if headers[":path"].starts_with?("/api/")
    stream.priority = 255  # Highest priority
  else
    stream.priority = 16   # Default priority
  end
}
```

### Custom HPACK Settings

Configure header compression:

```crystal
server = HT2::Server.new(
  handler: handler,
  max_header_list_size: 16384,  # 16KB max header size
  # Server will negotiate these settings with clients
)
```

### Connection Callbacks

For advanced connection handling:

```crystal
connection = HT2::Connection.new(socket, HT2::Connection::Type::Server)

# Set up callbacks
connection.on_frame = ->(frame) {
  Log.debug { "Received frame: #{frame.type}" }
}

connection.on_goaway = ->(last_stream_id, error_code) {
  Log.info { "GOAWAY received: last_stream=#{last_stream_id}, error=#{error_code}" }
}

connection.on_settings = ->(settings) {
  Log.info { "Settings updated: #{settings}" }
}
```

## Performance Tuning

### Buffer Pool Configuration

```crystal
# Configure global buffer pool
HT2::BufferPool.configure(
  max_pool_size: 1000,        # Maximum buffers in pool
  buffer_size: 16384,         # Default buffer size
  trim_threshold: 0.75        # Trim pool when 75% idle
)
```

### Adaptive Flow Control

Enable adaptive flow control for better throughput:

```crystal
# Server with adaptive flow control
server = HT2::Server.new(
  handler: handler,
  initial_window_size: 1_048_576  # 1MB initial window
)

# The server will automatically adjust window sizes based on:
# - Network conditions
# - Client consumption rate
# - Available memory
```

### Zero-Copy Optimizations

For high-performance file serving:

```crystal
handler = ->(request : HT2::Request, response : HT2::Response) {
  if request.path.starts_with?("/static/")
    file_path = File.join("public", request.path[8..])
    
    if File.exists?(file_path)
      response.headers["content-type"] = mime_type_for(file_path)
      response.headers["content-length"] = File.size(file_path).to_s
      
      # Use zero-copy file transfer
      File.open(file_path) do |file|
        IO.copy(file, response.stream)
      end
    else
      response.status = 404
    end
  end
  response.close
}
```

### Worker Pool Tuning

```crystal
# For CPU-bound workloads
cpu_bound_server = HT2::Server.new(
  handler: handler,
  worker_pool_size: System.cpu_count * 2
)

# for IO-bound workloads
io_bound_server = HT2::Server.new(
  handler: handler,
  worker_pool_size: 100  # Higher concurrency
)
```

## Monitoring & Metrics

### Connection Metrics

```crystal
# Access server connection metrics
server.connections.each do |conn|
  metrics = conn.metrics
  
  puts "Connection: #{conn.remote_address}"
  puts "  Streams created: #{metrics.streams_created}"
  puts "  Bytes sent: #{metrics.bytes_sent}"
  puts "  Bytes received: #{metrics.bytes_received}"
  puts "  Current streams: #{metrics.current_streams}"
end
```

### Performance Metrics

```crystal
# Create a monitoring endpoint
monitoring_handler = ->(request : HT2::Request, response : HT2::Response) {
  case request.path
  when "/metrics"
    metrics = server.performance_metrics
    
    response.headers["content-type"] = "application/json"
    response.write({
      "throughput" => {
        "bytes_per_second_sent" => metrics.bytes_per_second_sent,
        "bytes_per_second_received" => metrics.bytes_per_second_received
      },
      "latency" => {
        "p50_ms" => metrics.percentile_latency(50),
        "p90_ms" => metrics.percentile_latency(90),
        "p99_ms" => metrics.percentile_latency(99)
      },
      "connections" => {
        "active" => server.active_connections,
        "total" => server.total_connections
      }
    }.to_json.to_slice)
  end
  response.close
}
```

### Debug Mode

Enable detailed frame logging:

```crystal
# Enable debug mode
HT2::DebugMode.configure(
  enabled: true,
  log_frames: true,
  log_raw_bytes: false  # Only for deep debugging
)

# Or set via environment
# CRYSTAL_LOG_LEVEL=DEBUG HT2_DEBUG=1 ./myapp
```

### Stream Lifecycle Tracing

For debugging stream issues:

```crystal
# Enable stream tracing
conn.lifecycle_tracer.enabled = true

# Get stream history
history = conn.lifecycle_tracer.stream_history(stream_id)
history.events.each do |event|
  puts "#{event.timestamp}: #{event.type} - #{event.details}"
end

# Get full trace report
report = conn.lifecycle_tracer.generate_report
puts report
```

## Best Practices

### 1. Always Close Responses

```crystal
handler = ->(request, response) {
  begin
    # Handle request
    response.write(data.to_slice)
  ensure
    response.close  # Always close!
  end
}
```

### 2. Set Content-Type Headers

```crystal
response.headers["content-type"] = "application/json"
response.write(data.to_json.to_slice)
```

### 3. Handle Slow Clients

```crystal
handler = ->(request, response) {
  # Check backpressure before writing large responses
  if response.stream.connection.backpressure_level > 0.9
    Log.warn { "High backpressure, throttling response" }
    sleep 100.milliseconds
  end
  
  response.write(large_data.to_slice)
  response.close
}
```

### 4. Manage Server Connections

```crystal
# Monitor active connections in server
handler = ->(request, response) {
  conn = request.connection
  if conn.active_streams > 100
    Log.warn { "High stream count: #{conn.active_streams}" }
  end
  
  # Handle request...
  response.close
}
```

### 5. Monitor Performance

```crystal
spawn do
  loop do
    metrics = server.performance_metrics
    Log.info { "Throughput: #{metrics.bytes_per_second_sent} B/s" }
    Log.info { "Active connections: #{server.active_connections}" }
    sleep 30.seconds
  end
end
```