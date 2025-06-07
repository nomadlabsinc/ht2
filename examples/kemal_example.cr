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
  key : OpenSSL::PKey::RSA = OpenSSL::PKey::RSA.new(2048)

  cert : OpenSSL::X509::Certificate = OpenSSL::X509::Certificate.new
  cert.version = 2
  cert.serial = 1
  cert.subject = OpenSSL::X509::Name.new([["CN", "localhost"]])
  cert.issuer = cert.subject
  cert.public_key = key.public_key
  cert.not_before = Time.utc
  cert.not_after = Time.utc + 365.days

  # Add extensions for localhost
  extension_factory = OpenSSL::X509::ExtensionFactory.new
  extension_factory.subject_certificate = cert
  extension_factory.issuer_certificate = cert

  cert.add_extension(extension_factory.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1", false))
  cert.add_extension(extension_factory.create_extension("keyUsage", "digitalSignature,keyEncipherment", true))

  cert.sign(key, OpenSSL::Digest.new("SHA256"))

  context : OpenSSL::SSL::Context::Server = OpenSSL::SSL::Context::Server.new
  context.certificate_chain = cert.to_pem
  context.private_key = key.to_pem
  context.alpn_protocol = "h2"

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
