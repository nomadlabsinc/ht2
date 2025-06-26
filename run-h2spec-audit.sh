#!/bin/bash

# Clean up any existing containers and network
docker rm -f ht2-server h2spec-runner 2>/dev/null || true
docker network rm h2spec-net 2>/dev/null || true

# Create a Docker network for testing
echo "Creating Docker network..."
docker network create h2spec-net

# Build the h2spec Docker image
echo "Building h2spec Docker image..."
docker build -f Dockerfile.h2spec -t ht2-h2spec .

# Start the HT2 server in Docker with network alias
echo "Starting ht2 server in Docker..."
docker run -d --name ht2-server --network h2spec-net --network-alias ht2-server ht2-h2spec ./basic_server --host 0.0.0.0

# Wait for server to be ready
echo "Waiting for server to be ready..."
sleep 5

# Check if server is running
if ! docker ps | grep -q ht2-server; then
    echo "Server failed to start"
    docker logs ht2-server
    exit 1
fi

# Run h2spec tests using the same network
echo "Running h2spec tests..."
docker run --rm --name h2spec-runner --network h2spec-net summerwind/h2spec -h ht2-server -p 8443 -t -k

# Generate detailed test report
echo "Generating test report..."
docker run --rm --name h2spec-runner --network h2spec-net summerwind/h2spec -h ht2-server -p 8443 -t -k > h2spec_results.txt

# Parse results from text output
echo "Parsing results..."
if [ -f h2spec_results.txt ]; then
    # Extract summary from the last line
    summary=$(tail -n 1 h2spec_results.txt)
    echo "Summary: $summary"
fi

# Generate markdown report
echo "# h2spec Test Results" > h2spec_results.md
echo "" >> h2spec_results.md
echo "## Summary" >> h2spec_results.md
echo "" >> h2spec_results.md
if [ -f h2spec_results.txt ]; then
    tail -n 5 h2spec_results.txt >> h2spec_results.md
fi

# Clean up
echo "Cleaning up..."
docker rm -f ht2-server
docker network rm h2spec-net

echo "Done! Results saved to:"
echo "  - h2spec_results.json (JSON format)"
echo "  - h2spec_results.txt (Human readable)"
echo "  - h2spec_results.md (Markdown summary)"