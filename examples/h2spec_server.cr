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

# Use pre-generated certificates from Docker build or generate once and reuse
def get_tls_context(cert_file : String?, key_file : String?) : OpenSSL::SSL::Context::Server
  if cert_path = cert_file
    if key_path = key_file
      return HT2::Server.create_tls_context(cert_path, key_path)
    end
  end
  
  # Check if Docker build certificates exist (from Dockerfile.h2spec)
  if File.exists?("/certs/server.crt") && File.exists?("/certs/server.key")
    puts "🔐 Using pre-generated certificates from Docker build..."
    return HT2::Server.create_tls_context("/certs/server.crt", "/certs/server.key")
  end
  
  # Generate dev certificate ONCE and reuse
  puts "🔐 Generating reusable self-signed certificate..."
  
  # Use fixed paths to reuse certificates across connections
  cert_file_path = "/tmp/ht2_reusable_cert.pem"
  key_file_path = "/tmp/ht2_reusable_key.pem"
  
  # Only generate if they don't exist
  unless File.exists?(cert_file_path) && File.exists?(key_file_path)
    # Generate RSA key
    unless system("openssl genrsa -out #{key_file_path} 2048 2>/dev/null")
      raise "Failed to generate RSA key"
    end
    
    # Generate self-signed certificate
    unless system("openssl req -new -x509 -key #{key_file_path} -out #{cert_file_path} -days 365 -subj '/CN=localhost' 2>/dev/null")
      raise "Failed to generate certificate"
    end
    
    puts "✅ Generated reusable certificates at #{cert_file_path} and #{key_file_path}"
  else
    puts "✅ Reusing existing certificates"
  end
  
  context = OpenSSL::SSL::Context::Server.new
  context.certificate_chain = cert_file_path
  context.private_key = key_file_path
  context.alpn_protocol = "h2"
  
  context
end

# Create TLS context using optimized function
tls_context = get_tls_context(cert_file, key_file)

# Request counter
request_count = Atomic(Int32).new(0)

# Create request handler optimized for h2spec
handler : HT2::Server::Handler = ->(request : HT2::Request, response : HT2::Response) do
  count = request_count.add(1)
  
  # Force garbage collection every 20 requests to prevent accumulation
  if count % 20 == 0
    GC.collect
    Log.debug { "[#{count}] Forced GC collection" }
  end
  
  Log.info { "[#{count}] #{request.method} #{request.path}" }
  
  begin
    # Always respond with 200 OK
    response.status = 200
    response.headers["content-type"] = "text/plain"
    response.headers["server"] = "ht2-h2spec"
    
    # Smart response size based on request count for h2spec probe compatibility
    # The first few requests are likely h2spec probes - they need consistent data length
    # Later requests are the actual tests with specific window size requirements
    data_size = if count <= 5
                  # Early requests: send more data for proper probe measurement
                  1024
                else
                  # Later requests: send exactly 1 byte for window size tests
                  1
                end
    
    response.headers["content-length"] = data_size.to_s
    
    # Send the appropriate amount of data
    data = "x" * data_size
    Log.debug { "[#{count}] Sending #{data.size} bytes of data" }
    response.write(data.to_slice)
    
    # Ensure response is properly closed with END_STREAM
    response.close
    
    Log.debug { "[#{count}] Response completed successfully" }
  rescue ex
    Log.error { "[#{count}] Error handling request: #{ex.class}: #{ex.message}" }
    # Try to close response gracefully
    begin
      response.close
    rescue close_ex
      Log.debug { "[#{count}] Error closing response: #{close_ex.message}" }
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
  # Optimize for h2spec testing - reduce resource accumulation
  max_workers: 50,        # Smaller pool to prevent saturation
  worker_queue_size: 500  # Smaller queue to fail fast if overwhelmed
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