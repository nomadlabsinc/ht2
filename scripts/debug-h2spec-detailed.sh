#!/bin/bash

# Clean up
docker rm -f ht2-server h2spec-runner 2>/dev/null || true
docker network rm h2spec-net 2>/dev/null || true

# Create network
docker network create h2spec-net

# Build and start server with debug logging
docker build -f Dockerfile.h2spec -t ht2-h2spec .

# Start server with debug logging enabled
echo "Starting server with debug logging..."
docker run -d --name ht2-server --network h2spec-net --network-alias ht2-server \
  -e LOG_LEVEL=debug \
  ht2-h2spec ./basic_server --host 0.0.0.0

# Wait for server
sleep 5

# Run specific h2spec test
echo "Running specific h2spec test: 3.1 (DATA frame)"
docker run --rm --name h2spec-runner --network h2spec-net summerwind/h2spec -h ht2-server -p 8443 -t -k -v 3.1

# Show detailed server logs
echo -e "\n=== Full server logs ==="
docker logs ht2-server 2>&1

# Cleanup
docker rm -f ht2-server
docker network rm h2spec-net