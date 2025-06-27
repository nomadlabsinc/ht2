#!/usr/bin/env crystal

require "../src/ht2"
require "log"

Log.setup(:debug)

# Generate self-signed certificate for testing
system("openssl req -x509 -newkey rsa:2048 -keyout /tmp/server.key -out /tmp/server.crt -days 1 -nodes -subj '/CN=localhost' 2>/dev/null") unless File.exists?("/tmp/server.key")

# Create TLS context
tls_context = HT2::Server.create_tls_context("/tmp/server.crt", "/tmp/server.key")

# Track stream windows
stream_windows = {} of UInt32 => Int64

# Create a test server specifically for h2spec flow control tests
server = HT2::Server.new(
  host: "0.0.0.0",
  port: 9443,
  tls_context: tls_context,
  handler: ->(request : HT2::Request, response : HT2::Response) do
    stream_id = response.stream.id
    window = response.stream.send_window_size
    stream_windows[stream_id] = window

    Log.info { "Request: #{request.method} #{request.path} on stream #{stream_id}, window=#{window}" }

    # For h2spec tests, send a simple response
    response.status = 200
    response.headers["content-type"] = "text/plain"

    # Check if this is a flow control test (window is very small)
    if window <= 10 && window > 0
      Log.info { "Flow control test detected: window=#{window}, sending exactly #{window} bytes" }
      # Send exactly window bytes
      test_data = "x" * window
      begin
        response.write(test_data.to_slice)
        Log.info { "Successfully sent #{window} bytes on stream #{stream_id}" }
      rescue ex
        Log.error { "Error writing #{window} bytes: #{ex.message}" }
      end
    elsif window == 0
      Log.info { "Window is 0, not sending any data initially" }
      # Don't send data when window is 0
    else
      # Normal response
      test_data = "x" * 100
      begin
        response.write(test_data.to_slice)
      rescue ex
        Log.error { "Error writing response: #{ex.message}" }
      end
    end

    response.close
  end
)

# Monitor settings changes
server.on_settings = ->(settings : HT2::SettingsFrame::Settings) do
  if settings.has_key?(HT2::SettingsParameter::INITIAL_WINDOW_SIZE)
    Log.info { "SETTINGS: INITIAL_WINDOW_SIZE changed to #{settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE]}" }
  end
end if server.responds_to?(:on_settings=)

# H2spec debug server listening on 0.0.0.0:9443
# Run h2spec with: h2spec -h localhost -p 9443 -t
server.listen
