#!/usr/bin/env crystal

require "../src/ht2"
require "log"

Log.setup(:debug)

# Create a test server specifically for h2spec flow control tests
server = HT2::Server.new(
  host: "0.0.0.0",
  port: 9080,
  handler: ->(request : HT2::Request, response : HT2::Response) do
    Log.info { "Request: #{request.method} #{request.path}" }

    # For h2spec tests, send a simple response
    response.status = 200
    response.headers["content-type"] = "text/plain"

    # Send enough data to test flow control
    # h2spec expects us to send data according to the window size
    test_data = "x" * 100 # 100 bytes of data

    begin
      response.write(test_data.to_slice)
    rescue ex
      Log.error { "Error writing response: #{ex.message}" }
    ensure
      response.close
    end
  end
)

# H2spec test server listening on 0.0.0.0:9080
# Run h2spec with: h2spec -h localhost -p 9080 -t
server.listen
