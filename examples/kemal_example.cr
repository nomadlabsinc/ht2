require "kemal"
require "../src/ht2"

# Example: Kemal application running over HTTP/2

# Define Kemal routes
get "/" do |env|
  "Welcome to Kemal over HTTP/2!"
end

get "/json" do |env|
  env.response.content_type = "application/json"
  {
    message:   "Hello from HTTP/2",
    protocol:  "HTTP/2",
    timestamp: Time.utc.to_unix,
  }.to_json
end

post "/echo" do |env|
  body : String = env.request.body.try(&.gets_to_end) || ""
  {
    received: body,
    length:   body.bytesize,
    headers:  env.request.headers.to_h,
  }.to_json
end

get "/stream/:id" do |env|
  id : String = env.params.url["id"]
  "Stream ID: #{id}"
end

ws "/websocket" do |socket|
  socket.send "Connected via HTTP/2 upgrade!"

  socket.on_message do |message|
    socket.send "Echo: #{message}"
  end
end

# Create HTTP/2 adapter for Kemal
class KemalHTTP2Adapter
  def self.create_handler : HT2::Server::Handler
    # Build Kemal's handler chain
    kemal_handlers = Kemal.config.handlers

    ->(request : HT2::Request, response : HT2::Response) do
      begin
        # Convert HTTP/2 request to Kemal-compatible request
        http_request : HTTP::Request = request.to_lucky_request
        http_response : HTTP::Server::Response = HTTP::Server::Response.new(IO::Memory.new)
        context : HTTP::Server::Context = HTTP::Server::Context.new(http_request, http_response)

        # Process through Kemal handlers
        kemal_handlers.each { |handler| handler.call(context) }

        # Convert response back to HTTP/2
        response.status = http_response.status_code

        # Copy headers (skip connection-specific ones)
        http_response.headers.each do |name, values|
          next if ["connection", "keep-alive", "transfer-encoding"].includes?(name.downcase)
          values.each { |value| response.headers[name] = value }
        end

        # Copy body
        if output = http_response.@output
          output.rewind
          body : String = output.gets_to_end
          response.write(body.to_slice) unless body.empty?
        end

        response.close
      rescue ex
        # Handle errors
        response.status = 500
        response.headers["content-type"] = "text/plain"
        response.write("Internal Server Error: #{ex.message}".to_slice)
        response.close
      end
    end
  end
end

# Set up Kemal (disable built-in server)
Kemal.config.env = "production"
Kemal.config.serve_static = false # Handle static files via HTTP/2

# Generate self-signed certificate for development
def generate_dev_certificate : OpenSSL::SSL::Context::Server
  # Generate temporary file paths
  temp_key_file = "#{Dir.tempdir}/kemal_ht2_key_#{Process.pid}.pem"
  temp_cert_file = "#{Dir.tempdir}/kemal_ht2_cert_#{Process.pid}.pem"

  # Generate RSA key using OpenSSL command line
  unless system("openssl genrsa -out #{temp_key_file} 2048 2>/dev/null")
    raise "Failed to generate RSA key"
  end

  # Generate self-signed certificate with SAN extensions
  unless system("openssl req -new -x509 -key #{temp_key_file} -out #{temp_cert_file} -days 365 -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -addext 'keyUsage=digitalSignature,keyEncipherment' 2>/dev/null")
    # Fallback for older OpenSSL versions without -addext
    unless system("openssl req -new -x509 -key #{temp_key_file} -out #{temp_cert_file} -days 365 -subj '/CN=localhost' 2>/dev/null")
      raise "Failed to generate certificate"
    end
  end

  context : OpenSSL::SSL::Context::Server = OpenSSL::SSL::Context::Server.new
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

# Main execution
port : Int32 = 8443
tls_context : OpenSSL::SSL::Context::Server = generate_dev_certificate
handler : HT2::Server::Handler = KemalHTTP2Adapter.create_handler

# Create and start HTTP/2 server
server = HT2::Server.new(
  host: "localhost",
  port: port,
  handler: handler,
  tls_context: tls_context,
  max_concurrent_streams: 100_u32,
  initial_window_size: 65535_u32
)

puts "🚀 Kemal is running over HTTP/2!"
puts "🔒 URL: https://localhost:#{port}"
puts "📝 Routes:"
puts "   GET  /"
puts "   GET  /json"
puts "   POST /echo"
puts "   GET  /stream/:id"
puts ""
puts "Press Ctrl+C to stop"

# Handle shutdown
Signal::INT.trap do
  puts "\nShutting down..."
  server.close
  exit
end

server.listen
