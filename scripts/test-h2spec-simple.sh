#!/bin/bash

# Test if h2spec can run at all
echo "Testing h2spec..."
docker run --rm summerwind/h2spec --help 2>&1 | head -5

# Clean up old containers
docker rm -f ht2-server 2>/dev/null || true
docker network rm h2spec-net 2>/dev/null || true

# Create network
docker network create h2spec-net

# Start a simple server
echo -e "\nStarting server..."
docker run -d --name ht2-server --network h2spec-net --network-alias ht2-server ht2-h2spec ./basic_server --host 0.0.0.0
sleep 3

# Run just one simple test
echo -e "\nRunning single test..."
timeout 10 docker run --rm --network h2spec-net summerwind/h2spec -h ht2-server -p 8443 -t -k 2>&1 | grep -E "Starting HTTP/2|tests.*passed" | head -5

# Cleanup
docker rm -f ht2-server
docker network rm h2spec-net