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

# Run h2spec tests with shorter timeout per test (1 second instead of default 2)
# This will help identify which specific tests are timing out
echo "Running h2spec tests with 1 second timeout per test..."
START_TIME=$(date +%s)
docker run --rm --network h2spec-net summerwind/h2spec -h ht2-server -p 8443 -t -k -o 1 > h2spec_results_detailed.txt 2>&1
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "Total test duration: ${DURATION} seconds"

# Parse results
echo -e "\n=== H2SPEC TEST SUMMARY ==="
tail -5 h2spec_results_detailed.txt | grep -E "Finished|tests.*passed"

# Count different types of failures
echo -e "\n=== FAILURE BREAKDOWN ==="
echo -n "Total failures: "
grep -c "×" h2spec_results_detailed.txt

echo -n "Timeout failures: "
grep -c "Actual: Timeout" h2spec_results_detailed.txt

echo -n "RST_STREAM instead of GOAWAY: "
grep -B1 "Actual: RST_STREAM" h2spec_results_detailed.txt | grep -c "Expected: GOAWAY"

echo -n "Connection errors: "
grep -c "connection refused\|Unable to" h2spec_results_detailed.txt

echo -n "Other failures: "
OTHER=$(grep "×" h2spec_results_detailed.txt | grep -v -c "Timeout\|RST_STREAM\|connection refused\|Unable to")
echo $OTHER

# List all timeout failures
echo -e "\n=== TESTS FAILING WITH TIMEOUT ==="
grep -B3 "Actual: Timeout" h2spec_results_detailed.txt | grep "×" | sed 's/^[ \t]*//' | sort | uniq

# List RST_STREAM failures
echo -e "\n=== TESTS FAILING WITH RST_STREAM INSTEAD OF GOAWAY ==="
grep -B3 "Actual: RST_STREAM" h2spec_results_detailed.txt | grep -B2 "Expected: GOAWAY" | grep "×" | sed 's/^[ \t]*//' | sort | uniq

# List other failures
echo -e "\n=== OTHER FAILURES ==="
grep -A3 "×" h2spec_results_detailed.txt | grep -v "Timeout\|RST_STREAM.*GOAWAY" | grep "×" | sed 's/^[ \t]*//' | sort | uniq

# Cleanup
docker rm -f ht2-server
docker network rm h2spec-net