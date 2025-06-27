#!/usr/bin/env crystal

require "../src/ht2"
require "option_parser"
require "log"

# Enable info logging by default
Log.setup_from_env(
  default_level: :info,
  default_sources: "*"
)

# H2spec-compliant server that always sends exactly 1 byte of data
# This ensures h2spec's ServerDataLength probe always succeeds

# Configuration
host : String = "0.0.0.0"
port : Int32 = 8443
cert_file : String? = nil
key_file : String? = nil

# Parse command line options
OptionParser.parse do |parser|
  parser.banner = "Usage: h2spec_server [options]"

  parser.on("-h HOST", "--host=HOST", "Host to bind to (default: 0.0.0.0)") do |host_arg|
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

# Request counter
request_count = Atomic(Int32).new(0)

# Create request handler optimized for h2spec
handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
  count = request_count.add(1)
  Log.info { "[#{count}] #{request.method} #{request.path}" }
  
  begin
    # Always respond with 200 OK
    response.status = 200
    response.headers["content-type"] = "text/plain"
    response.headers["server"] = "ht2-h2spec"
    
    # Send exactly 1 byte of data
    # This is critical for h2spec flow control tests
    # The tests expect to be able to measure server data length
    response.write("x".to_slice)
    
    # Ensure response is properly closed
    response.close
    
    Log.debug { "[#{count}] Response sent successfully" }
  rescue ex
    Log.error { "[#{count}] Error handling request: #{ex.message}" }
    # Try to close response
    begin
      response.close
    rescue
      # Ignore errors when closing
    end
  end
end

# Create and configure server with h2spec-friendly settings
server = HT2::Server.new(
  host: host,
  port: port,
  handler: handler,
  tls_context: tls_context,
  # Use default settings that work well with h2spec
  max_concurrent_streams: 100_u32,
  initial_window_size: 65_535_u32,
  max_frame_size: 16_384_u32,
  # Increase worker pool for concurrent connections
  max_workers: 200,
  worker_queue_size: 2000
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
puts "🚀 HT2 H2spec Server"
puts "🔒 Listening on https://#{host}:#{port}"
puts "📝 This server always sends exactly 1 byte for h2spec compliance"
puts ""
puts "Run h2spec with:"
puts "  h2spec -h #{host} -p #{port} -t -k"
puts ""
puts "Press Ctrl+C to stop"
puts ""

server.listen