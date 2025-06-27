#!/usr/bin/env crystal

require "../src/ht2"
require "log"

Log.setup(:debug)

# Create a simple test server
server = HT2::Server.new(
  host: "localhost",
  port: 8443,
  handler: ->(request : HT2::Request, response : HT2::Response) do
    Log.debug { "Handler called for #{request.method} #{request.path}" }
    
    # Send a simple response with some data
    response.status = 200
    response.headers["content-type"] = "text/plain"
    
    # Send data in small chunks to test flow control
    test_data = "Hello, HTTP/2! This is test data for flow control testing."
    response.write(test_data.to_slice)
    response.close
  end
)

puts "Starting test server on localhost:8443..."
server.listen