#!/bin/bash
# Wrapper script to run individual tests with timeout

TEST_FILE=$1
TIMEOUT=${2:-30}  # Default 30 second timeout per test file

if [ -z "$TEST_FILE" ]; then
    echo "Usage: $0 <test_file> [timeout_seconds]"
    exit 1
fi

# Run the test with timeout
timeout --preserve-status $TIMEOUT crystal spec --no-color "$TEST_FILE"
EXIT_CODE=$?

if [ $EXIT_CODE -eq 124 ]; then
    echo "Test timed out after ${TIMEOUT}s: $TEST_FILE"
    exit 1
elif [ $EXIT_CODE -ne 0 ]; then
    echo "Test failed: $TEST_FILE"
    exit $EXIT_CODE
fi

exit 0