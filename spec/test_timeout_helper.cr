# Global test timeout helper
# Ensures tests don't hang indefinitely

# Set up a global timeout for the entire test suite
spawn do
  # Wait for 4 minutes (CI has 5 minute timeout)
  sleep 4.minutes

  # If we reach here, tests are taking too long
  STDERR.puts "\n\nERROR: Test suite timeout after 4 minutes!"
  STDERR.puts "This usually indicates a hanging test."
  STDERR.puts "Check for:"
  STDERR.puts "  - Servers not closing properly"
  STDERR.puts "  - Blocking operations without timeouts"
  STDERR.puts "  - Infinite loops in tests"
  STDERR.flush

  # Force exit
  exit 1
end
