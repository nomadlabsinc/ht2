#!/bin/bash

# Clean up
docker rm -f ht2-server h2spec-runner 2>/dev/null || true
docker network rm h2spec-net 2>/dev/null || true

# Create network
docker network create h2spec-net

# Build and start server
docker build -f Dockerfile.h2spec -t ht2-h2spec .
docker run -d --name ht2-server --network h2spec-net --network-alias ht2-server ht2-h2spec ./basic_server --host 0.0.0.0

# Wait for server
sleep 5

# Run specific h2spec test
echo "Running specific h2spec test: 3.1/1 (DATA frame)"
docker run --rm --name h2spec-runner --network h2spec-net summerwind/h2spec -h ht2-server -p 8443 -t -k -s "3.1/1"

# Check logs
echo -e "\n=== Server logs ==="
docker logs ht2-server 2>&1 | tail -30

# Cleanup
docker rm -f ht2-server
docker network rm h2spec-net