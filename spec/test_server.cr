#!/usr/bin/env crystal

require "../src/ht2"
require "log"

Log.setup(:debug)

# Create a simple test server with h2c support (no TLS)
server = HT2::Server.new(
  host: "localhost",
  port: 8443,
  handler: ->(request : HT2::Request, response : HT2::Response) do
    Log.debug { "Handler called for #{request.method} #{request.path}" }

    # Send a simple response with some data
    response.status = 200
    response.headers["content-type"] = "text/plain"

    # Send enough data for h2spec to measure (at least 100 bytes)
    # h2spec expects servers to send a reasonable amount of data
    test_data = "x" * 100 # 100 bytes of 'x' characters
    response.write(test_data.to_slice)
    response.close
  end,
  enable_h2c: true # Enable h2c for non-TLS HTTP/2
)

# Starting test server on localhost:8443...
server.listen
