require "../src/ht2"

# H2C Server Example
server = HT2::Server.new(
  host: "127.0.0.1",
  port: 8080,
  handler: ->(request : HT2::Request, response : HT2::Response) {
    response.status = 200
    response.headers["content-type"] = "text/plain"
    response.write("Hello from H2C! Path: #{request.path}".to_slice)
    nil
  },
  enable_h2c: true
)

puts "Starting H2C server on http://127.0.0.1:8080"
puts "Server supports both HTTP/1.1 Upgrade and direct HTTP/2"

# Start server in a fiber
spawn do
  server.listen
end

# Give server time to start
sleep 0.5.seconds

# H2C Client Example
client = HT2::Client.new(enable_h2c: true)

puts "\nMaking H2C requests..."

begin
  # First request will try upgrade
  response = client.get("http://127.0.0.1:8080/test1")
  puts "Response 1: #{response.body}"
rescue ex
  puts "Error: #{ex.message}"
  puts ex.backtrace.join("\n")
end

# Second request will use prior knowledge (cached)
response = client.get("http://127.0.0.1:8080/test2")
puts "Response 2: #{response.body}"

# Make multiple concurrent requests
channels = [] of Channel(String)

5.times do |i|
  channel = Channel(String).new
  channels << channel

  spawn do
    resp = client.get("http://127.0.0.1:8080/concurrent/#{i}")
    channel.send(resp.body)
  end
end

puts "\nConcurrent responses:"
channels.each_with_index do |channel, i|
  puts "  #{i}: #{channel.receive}"
end

# Clean up
client.close
server.close

puts "\nH2C example completed!"
