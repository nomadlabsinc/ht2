require "../src/ht2"

# H2C Server Example
server = HT2::Server.new(
  host: "127.0.0.1",
  port: 8080,
  handler: ->(request : HT2::Request, response : HT2::Response) {
    response.status = 200
    response.headers["content-type"] = "text/plain"
    response.write("Hello from H2C! Method: #{request.method}, Path: #{request.path}".to_slice)
    nil
  },
  enable_h2c: true
)

puts "Starting H2C server on http://127.0.0.1:8080"
puts "Server supports HTTP/1.1 Upgrade to HTTP/2 (h2c)"
puts ""
puts "Test with curl:"
puts "  curl -v --http2 http://127.0.0.1:8080/"
puts ""
puts "Or with HTTP/1.1 upgrade headers:"
puts "  curl -v -H 'Connection: Upgrade' -H 'Upgrade: h2c' -H 'HTTP2-Settings: AAMAAABkAAQCAAAAAAIAAAAA' http://127.0.0.1:8080/"
puts ""
puts "Press Ctrl+C to stop the server"

# Start server
server.listen
