#!/bin/bash

# Script to run a single h2spec test
if [ $# -lt 2 ]; then
    echo "Usage: $0 <section> <test-name>"
    echo "Example: $0 '2.3.3' 'Index Address Space'"
    exit 1
fi

SECTION=$1
TEST_NAME=$2

# Clean up
docker rm -f ht2-server ht2-h2spec 2>/dev/null || true

# Build
echo "Building Docker image..."
docker build -f Dockerfile.h2spec -t ht2-h2spec . --quiet

# Create network
docker network create h2spec-test 2>/dev/null || true

# Start server
echo "Starting server..."
docker run -d --name ht2-server --network h2spec-test \
    -e HT2_LOG_LEVEL=DEBUG \
    ht2-h2spec ./basic_server --host 0.0.0.0

# Wait for server
sleep 2

# Run specific h2spec test with debug output
echo "Running h2spec test: $SECTION - $TEST_NAME"
docker run --rm --name ht2-h2spec --network h2spec-test \
    summerwind/h2spec:2.6.0 \
    -h ht2-server -p 8443 -t --timeout 5 \
    -k "$SECTION"

# Show server logs
echo -e "\n=== Server logs ==="
docker logs ht2-server 2>&1 | tail -50

# Cleanup
docker rm -f ht2-server ht2-h2spec
docker network rm h2spec-test 2>/dev/null || true