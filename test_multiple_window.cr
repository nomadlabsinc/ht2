# Test to understand the multiple SETTINGS_INITIAL_WINDOW_SIZE behavior

# When h2spec sends multiple INITIAL_WINDOW_SIZE values:
# 1. First it might set to 0 (blocking all streams)
# 2. Then it sets to a positive value
# 3. It expects the server to be able to send exactly that amount of data

# The "Unable to get server data length" error suggests:
# - h2spec is trying to determine how much data the server can send
# - It likely creates a stream, then changes window size with multiple values
# - It expects the server to send data matching the final window size

puts "Expected test flow:"
puts "1. Client sends SETTINGS with INITIAL_WINDOW_SIZE=0"
puts "2. Client sends HEADERS to create stream (window=0, can't send data)"
puts "3. Client sends SETTINGS with multiple INITIAL_WINDOW_SIZE values"
puts "   - First value might be 0 again"
puts "   - Second value is positive (e.g., 1 or 65536)"
puts "4. Server should be able to send exactly that many bytes"
puts ""
puts "The test fails if:"
puts "- Server doesn't update existing stream windows"
puts "- Server doesn't process settings in order"
puts "- Server doesn't notify blocked streams when window opens"
