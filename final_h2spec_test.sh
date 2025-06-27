#\!/bin/bash

echo "=== Testing h2spec locally vs Docker ==="

# Build server
echo "Building server..."
crystal build examples/basic_server.cr --release -o final_test_server

# Test 1: Local server with localhost binding
echo -e "\n1. Testing with localhost binding..."
./final_test_server --host localhost --port 8443 > local_localhost.log 2>&1 &
PID1=$\!
sleep 3
h2spec -h localhost -p 8443 -t -k 2>&1 | grep -A 2 "multiple values of SETTINGS"
kill $PID1 2>/dev/null || true

# Test 2: Local server with 0.0.0.0 binding
echo -e "\n2. Testing with 0.0.0.0 binding..."
./final_test_server --host 0.0.0.0 --port 8443 > local_0000.log 2>&1 &
PID2=$\!
sleep 3
h2spec -h localhost -p 8443 -t -k 2>&1 | grep -A 2 "multiple values of SETTINGS"
kill $PID2 2>/dev/null || true

# Test 3: Check Docker test
echo -e "\n3. Testing with Docker..."
docker build -f Dockerfile.h2spec -t ht2-h2spec-final . --quiet
docker rm -f ht2-test-final 2>/dev/null || true
docker run -d --name ht2-test-final -p 8443:8443 ht2-h2spec-final ./basic_server --host 0.0.0.0
sleep 5
h2spec -h localhost -p 8443 -t -k 2>&1 | grep -A 2 "multiple values of SETTINGS"
docker rm -f ht2-test-final

echo -e "\nDone\!"
