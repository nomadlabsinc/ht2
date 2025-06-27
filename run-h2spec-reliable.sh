#!/bin/bash

set -e

echo "Building h2spec Docker image..."
docker build -f Dockerfile.h2spec -t ht2-h2spec . --quiet

# Clean up any existing containers
docker rm -f ht2-server ht2-h2spec 2>/dev/null || true
docker network rm h2spec-net 2>/dev/null || true

# Create network
docker network create h2spec-net

# Start server with increased connection limits and timeouts
echo "Starting h2spec-optimized server..."
docker run -d --name ht2-server --network h2spec-net \
    -e HT2_LOG_LEVEL=INFO \
    -e LOG_LEVEL=INFO \
    --ulimit nofile=65536:65536 \
    --memory=512m \
    --cpus=2 \
    ht2-h2spec sh -c "
        # Use the h2spec-optimized server if it exists, otherwise use basic_server
        if [ -f /app/h2spec_server ]; then
            echo 'Using h2spec-optimized server'
            exec /app/h2spec_server
        else
            echo 'Using basic server'
            exec /app/basic_server --host 0.0.0.0
        fi
    "

# Wait for server to be fully ready
echo "Waiting for server to be ready..."
for i in {1..30}; do
    if docker exec ht2-server curl -k -f https://localhost:8443/ >/dev/null 2>&1; then
        echo "Server is ready!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "Server failed to start"
        docker logs ht2-server
        exit 1
    fi
    sleep 1
done

# Give server extra time to stabilize
sleep 2

# Run h2spec with increased timeout and connection reuse disabled
echo "Running h2spec tests..."
docker run --rm --name ht2-h2spec --network h2spec-net \
    --ulimit nofile=65536:65536 \
    summerwind/h2spec:2.6.0 \
    -h ht2-server -p 8443 -t -k -o 10

# Capture exit code
EXIT_CODE=$?

# Show server logs if tests failed
if [ $EXIT_CODE -ne 0 ]; then
    echo "Tests failed. Server logs:"
    docker logs ht2-server --tail 50
fi

# Cleanup
docker rm -f ht2-server ht2-h2spec
docker network rm h2spec-net

exit $EXIT_CODE