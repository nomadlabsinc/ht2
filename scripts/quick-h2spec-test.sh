#!/bin/bash

# Clean up
docker rm -f ht2-server 2>/dev/null || true
docker network rm h2spec-net 2>/dev/null || true

# Create network
docker network create h2spec-net

# Build and start server
docker build -f Dockerfile.h2spec -t ht2-h2spec . --quiet
docker run -d --name ht2-server --network h2spec-net --network-alias ht2-server ht2-h2spec ./basic_server --host 0.0.0.0

# Wait for server
sleep 5

# Run h2spec tests and capture summary
echo "Running h2spec tests..."
docker run --rm --network h2spec-net summerwind/h2spec -h ht2-server -p 8443 -t -k 2>&1 | tee temp_results.txt

# Extract summary
echo -e "\n=== TEST SUMMARY ==="
tail -5 temp_results.txt

# Cleanup
docker rm -f ht2-server
docker network rm h2spec-net
rm -f temp_results.txt