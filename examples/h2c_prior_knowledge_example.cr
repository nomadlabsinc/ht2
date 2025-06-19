require "../src/ht2"

# This example demonstrates HTTP/2 Clear Text (h2c) with Prior Knowledge
# Prior knowledge means the client knows the server supports HTTP/2 and
# sends the HTTP/2 connection preface immediately without upgrade negotiation.

# Create an h2c server
server = HT2::Server.new(
  enable_h2c: true,
  handler: ->(request : HT2::Request, response : HT2::Response) {
    puts "Received #{request.method} #{request.path}"

    # Echo back information about the connection
    response.status = 200
    response.headers["content-type"] = "text/plain"

    body = String.build do |str|
      str << "HTTP/2 Clear Text Connection\n"
      str << "Method: #{request.method}\n"
      str << "Path: #{request.path}\n"
      str << "Headers:\n"
      request.headers.each do |name, value|
        str << "  #{name}: #{value}\n"
      end
    end

    response.write(body.to_slice)
  },
  host: "127.0.0.1",
  port: 8080,
)

puts "Starting h2c server on http://127.0.0.1:8080"
puts "Server supports both HTTP/1.1 upgrade and HTTP/2 prior knowledge"
puts ""

# Start server in background
spawn do
  server.listen
end

# Give server time to start
sleep 0.5

# Example 1: Client with prior knowledge
puts "Example 1: Client using HTTP/2 prior knowledge"
client_prior_knowledge = HT2::Client.new(
  enable_h2c: true,
  use_prior_knowledge: true
)

response = client_prior_knowledge.get("http://127.0.0.1:8080/prior-knowledge")
puts "Response status: #{response.status}"
puts "Response body:\n#{response.body}\n"
client_prior_knowledge.close

# Example 2: Client using HTTP/1.1 upgrade
puts "Example 2: Client using HTTP/1.1 upgrade"
client_upgrade = HT2::Client.new(
  enable_h2c: true,
  use_prior_knowledge: false
)

response = client_upgrade.get("http://127.0.0.1:8080/upgrade")
puts "Response status: #{response.status}"
puts "Response body:\n#{response.body}\n"
client_upgrade.close

# Example 3: Multiple requests with connection reuse
puts "Example 3: Multiple requests with connection reuse"
client_multi = HT2::Client.new(
  enable_h2c: true,
  use_prior_knowledge: true
)

3.times do |i|
  response = client_multi.get("http://127.0.0.1:8080/request-#{i + 1}")
  puts "Request #{i + 1} - Status: #{response.status}, Path from body: #{response.body.lines[2]}"
end
client_multi.close

# Example 4: Using curl with prior knowledge
puts "\nExample 4: Test with curl"
puts "You can test the server with curl using prior knowledge:"
puts "  curl --http2-prior-knowledge http://127.0.0.1:8080/curl-test"
puts ""
puts "Or with HTTP/1.1 upgrade:"
puts "  curl --http2 http://127.0.0.1:8080/curl-upgrade"
puts ""

puts "Press Ctrl+C to stop the server..."

# Keep server running
sleep
