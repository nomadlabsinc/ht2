require "../src/ht2"
require "option_parser"
require "json"
require "log"

# Enable debug logging
Log.setup_from_env(
  default_level: :debug,
  default_sources: "*"
)

# Basic HTTP/2 server example demonstrating core functionality

# Configuration
host : String = "localhost"
port : Int32 = 8443
cert_file : String? = nil
key_file : String? = nil

# Parse command line options
OptionParser.parse do |parser|
  parser.banner = "Usage: basic_server [options]"

  parser.on("-h HOST", "--host=HOST", "Host to bind to (default: localhost)") do |host_arg|
    host = host_arg
  end

  parser.on("-p PORT", "--port=PORT", "Port to bind to (default: 8443)") do |port_arg|
    port = port_arg.to_i
  end

  parser.on("-c CERT", "--cert=CERT", "TLS certificate file") do |cert_arg|
    cert_file = cert_arg
  end

  parser.on("-k KEY", "--key=KEY", "TLS private key file") do |k|
    key_file = k
  end

  parser.on("--help", "Show this help") do
    puts parser
    exit
  end
end

# Generate self-signed certificate if not provided
def generate_dev_certificate : OpenSSL::SSL::Context::Server
  puts "🔐 Generating self-signed certificate for development..."

  # Generate temporary file paths
  temp_key_file = "#{Dir.tempdir}/ht2_dev_key_#{Process.pid}.pem"
  temp_cert_file = "#{Dir.tempdir}/ht2_dev_cert_#{Process.pid}.pem"

  # Generate RSA key using OpenSSL command line
  unless system("openssl genrsa -out #{temp_key_file} 2048 2>/dev/null")
    raise "Failed to generate RSA key"
  end

  # Generate self-signed certificate
  unless system("openssl req -new -x509 -key #{temp_key_file} -out #{temp_cert_file} -days 365 -subj '/CN=localhost' 2>/dev/null")
    raise "Failed to generate certificate"
  end

  context = OpenSSL::SSL::Context::Server.new
  context.certificate_chain = temp_cert_file
  context.private_key = temp_key_file
  context.alpn_protocol = "h2"

  # Clean up temp files on exit
  at_exit do
    File.delete(temp_key_file) if File.exists?(temp_key_file)
    File.delete(temp_cert_file) if File.exists?(temp_cert_file)
  end

  context
end

# Create TLS context
tls_context = if cert_path = cert_file
                if key_path = key_file
                  HT2::Server.create_tls_context(cert_path, key_path)
                else
                  generate_dev_certificate
                end
              else
                generate_dev_certificate
              end

# Request counter for demo
request_count = Atomic(Int32).new(0)
start_time = Time.utc

# Create request handler
handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
  count = request_count.add(1)

  case request.path
  when "/"
    # Home page
    response.status = 200
    response.headers["content-type"] = "text/html; charset=utf-8"
    response.write(<<-HTML
      <!DOCTYPE html>
      <html>
      <head>
        <title>HT2 Server</title>
        <style>
          body { font-family: -apple-system, system-ui, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; }
          h1 { color: #2e7d32; }
          .info { background: #f5f5f5; padding: 15px; border-radius: 5px; margin: 20px 0; }
          code { background: #e8e8e8; padding: 2px 5px; border-radius: 3px; }
          .endpoints { margin: 20px 0; }
          .endpoint { margin: 10px 0; padding: 10px; background: #fafafa; border-left: 3px solid #2e7d32; }
        </style>
      </head>
      <body>
        <h1>🚀 Welcome to HT2!</h1>
        <div class="info">
          <p><strong>Protocol:</strong> HTTP/2</p>
          <p><strong>Request #:</strong> #{count}</p>
          <p><strong>Uptime:</strong> #{Time.utc - start_time}</p>
        </div>

        <h2>Available Endpoints:</h2>
        <div class="endpoints">
          <div class="endpoint">
            <code>GET /</code> - This page
          </div>
          <div class="endpoint">
            <code>GET /info</code> - Server information (JSON)
          </div>
          <div class="endpoint">
            <code>POST /echo</code> - Echo back request body
          </div>
          <div class="endpoint">
            <code>GET /headers</code> - Show request headers
          </div>
          <div class="endpoint">
            <code>GET /large</code> - Large response (1MB)
          </div>
          <div class="endpoint">
            <code>GET /stream/:id</code> - Stream-specific response
          </div>
        </div>

        <h2>HTTP/2 Features:</h2>
        <ul>
          <li>Multiplexed streams</li>
          <li>Header compression (HPACK)</li>
          <li>Binary protocol</li>
          <li>Flow control</li>
          <li>Stream prioritization</li>
        </ul>
      </body>
      </html>
      HTML
      .to_slice)
  when "/info"
    # Server information as JSON
    response.status = 200
    response.headers["content-type"] = "application/json"
    response.write({
      server:         "HT2",
      version:        HT2::VERSION,
      protocol:       "HTTP/2",
      request_count:  count,
      uptime_seconds: (Time.utc - start_time).total_seconds.to_i,
      features:       {
        multiplexing:       true,
        server_push:        true,
        header_compression: "HPACK",
        flow_control:       true,
      },
    }.to_json.to_slice)
  when "/echo"
    # Echo back the request body
    if request.method != "POST"
      response.status = 405
      response.headers["allow"] = "POST"
      response.write("Method not allowed. Use POST.".to_slice)
    else
      body = request.body.gets_to_end
      response.status = 200
      response.headers["content-type"] = request.headers["content-type"]? || "text/plain"
      response.headers["x-echo-length"] = body.bytesize.to_s
      response.write(body.to_slice)
    end
  when "/headers"
    # Show all request headers
    response.status = 200
    response.headers["content-type"] = "application/json"

    headers_hash = Hash(String, String | Array(String)).new
    request.headers.each do |name, values|
      headers_hash[name] = values.size == 1 ? values.first : values
    end

    response.write({
      method:    request.method,
      path:      request.path,
      scheme:    request.scheme,
      authority: request.authority,
      headers:   headers_hash,
    }.to_json.to_slice)
  when "/large"
    # Send a large response (1MB)
    response.status = 200
    response.headers["content-type"] = "application/octet-stream"
    response.headers["content-length"] = (1024 * 1024).to_s

    # Send 1MB in 8KB chunks
    128.times do |i|
      chunk = Bytes.new(8192) { |j| ((i * 8192 + j) % 256).to_u8 }
      response.write(chunk)
    end
  when .starts_with?("/stream/")
    # Stream-specific response
    stream_id = request.path.split("/")[2]?
    response.status = 200
    response.headers["content-type"] = "text/plain"
    response.headers["x-stream-id"] = stream_id || "unknown"
    response.write("Response for stream: #{stream_id}".to_slice)
  else
    # 404 Not Found
    response.status = 404
    response.headers["content-type"] = "text/plain"
    response.write("Not Found: #{request.path}".to_slice)
  end

  response.close
rescue ex
  # Handle any errors
  response.status = 500
  response.headers["content-type"] = "text/plain"
  response.write("Internal Server Error: #{ex.message}".to_slice)
  response.close
end

# Create and configure server
server = HT2::Server.new(
  host: host,
  port: port,
  handler: handler,
  tls_context: tls_context,
  max_concurrent_streams: 100_u32,
  initial_window_size: 65_535_u32,
  max_frame_size: 16_384_u32
)

# Handle shutdown gracefully
shutdown = false
Signal::INT.trap do
  unless shutdown
    shutdown = true
    puts "\n🛑 Shutting down server..."
    spawn { server.close }
  end
end

# Start server
puts "🚀 HT2 Basic Server"
puts "🔒 Listening on https://#{host}:#{port}"
puts "📝 Try these endpoints:"
puts "   - https://#{host}:#{port}/"
puts "   - https://#{host}:#{port}/info"
puts "   - https://#{host}:#{port}/headers"
puts ""
puts "Press Ctrl+C to stop"
puts ""

server.listen
