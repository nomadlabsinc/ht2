#!/usr/bin/env crystal

require "../src/ht2"
require "log"

Log.setup(:debug)

# Generate self-signed certificate for testing
system("openssl req -x509 -newkey rsa:2048 -keyout /tmp/server.key -out /tmp/server.crt -days 1 -nodes -subj '/CN=localhost' 2>/dev/null") unless File.exists?("/tmp/server.key")

# Create TLS context
tls_context = HT2::Server.create_tls_context("/tmp/server.crt", "/tmp/server.key")

# Create a test server specifically for h2spec flow control tests
server = HT2::Server.new(
  host: "0.0.0.0",
  port: 9443,
  tls_context: tls_context,
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

# H2spec TLS test server listening on 0.0.0.0:9443
# Run h2spec with: h2spec -h localhost -p 9443 -t
server.listen
