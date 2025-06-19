# Ensure clean exit after all tests
at_exit do
  # Give fibers a brief moment to finish cleanly
  sleep 50.milliseconds
  # Force exit to prevent hanging from any remaining fibers
  Process.exit 0
end
