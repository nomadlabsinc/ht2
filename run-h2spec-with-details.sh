#!/bin/bash

# Clean up
docker rm -f ht2-server 2>/dev/null || true
docker network rm h2spec-net 2>/dev/null || true

# Create network
docker network create h2spec-net

# Build image
echo "Building Docker image..."
docker build -f Dockerfile.h2spec -t ht2-h2spec . --quiet

# Start server
echo "Starting server..."
docker run -d --name ht2-server --network h2spec-net --network-alias ht2-server ht2-h2spec ./basic_server --host 0.0.0.0

# Wait for server
sleep 5

# Run h2spec tests and save output
echo "Running h2spec tests..."
docker run --rm --network h2spec-net summerwind/h2spec -h ht2-server -p 8443 -t -k > h2spec_detailed_results.txt 2>&1

# Parse results
echo "=== H2SPEC TEST RESULTS ==="
tail -3 h2spec_detailed_results.txt

# Extract failures
echo -e "\n=== FAILURE BREAKDOWN ==="
echo "Timeouts:"
grep -B2 "Actual: Timeout" h2spec_detailed_results.txt | grep "×" | wc -l

echo -e "\nRST_STREAM instead of GOAWAY:"
grep -B2 "Actual: RST_STREAM" h2spec_detailed_results.txt | grep "Expected: GOAWAY" | wc -l

echo -e "\nConnection refused:"
grep "connection refused" h2spec_detailed_results.txt | wc -l

echo -e "\nOther failures:"
grep "×" h2spec_detailed_results.txt | grep -v "Timeout" | grep -v "RST_STREAM" | grep -v "connection refused" | wc -l

# Show all failures with reasons
echo -e "\n=== DETAILED FAILURES ==="
grep -A3 "×" h2spec_detailed_results.txt | grep -E "×|Expected:|Actual:" | sed 's/^[ \t]*//'

# Cleanup
docker rm -f ht2-server
docker network rm h2spec-net