#!/bin/bash

# Simple h2spec runner without complex analysis
echo "Building Docker image..."
docker build -f Dockerfile.h2spec -t ht2-h2spec . --quiet || exit 1

# Clean up
docker rm -f ht2-server ht2-h2spec 2>/dev/null || true
docker network create h2spec-net 2>/dev/null || true

# Start server
echo "Starting server..."
docker run -d --name ht2-server --network h2spec-net \
    -e HT2_LOG_LEVEL=INFO \
    ht2-h2spec ./basic_server --host 0.0.0.0

# Wait for server
sleep 2

# Run h2spec
echo "Running h2spec tests..."
docker run --rm --name ht2-h2spec --network h2spec-net \
    summerwind/h2spec:2.6.0 \
    -h ht2-server -p 8443 -t -k

# Cleanup
docker rm -f ht2-server ht2-h2spec
docker network rm h2spec-net