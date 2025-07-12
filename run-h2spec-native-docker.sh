#!/bin/bash

# Dockerized Native H2SPEC Test Runner
# Runs the native h2spec binary inside Docker for deterministic environment
# Usage: ./run-h2spec-native-docker.sh [--verbose] [--keep-server]

set -e

VERBOSE=false
KEEP_SERVER=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose)
            VERBOSE=true
            shift
            ;;
        --keep-server)
            KEEP_SERVER=true
            shift
            ;;
        *)
            echo "Usage: $0 [--verbose] [--keep-server]"
            echo "  --verbose     Show detailed output and server logs"
            echo "  --keep-server Keep server running after tests (for manual testing)"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}🐳 Dockerized Native H2SPEC Test Runner${NC}"
echo "=================================================="
echo "Running unmodified h2spec binary in Docker container"
echo "This ensures deterministic environment matching Crystal tests."
echo ""

echo -e "${BLUE}🏗️  Setting up Docker network...${NC}"

# Clean up any existing containers/networks
docker rm -f ht2-server-test 2>/dev/null || true
docker network rm h2spec-test-net 2>/dev/null || true

# Create network for container communication
docker network create h2spec-test-net

echo -e "${BLUE}🏗️  Starting server container...${NC}"

# Start server container using the same image as the project
SERVER_CONTAINER=$(docker run -d --name ht2-server-test \
    --network h2spec-test-net --network-alias ht2-server \
    -v "$(pwd):/app" \
    -w /app \
    robnomad/crystal:ubuntu-hoard \
    sh -c "
        apt-get update && apt-get install -y curl openssl && \
        crystal build examples/h2spec_server.cr -o h2spec_server --release && \
        openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 365 -nodes -subj '/CN=localhost' && \
        ./h2spec_server --host 0.0.0.0 --port 8443
    ")

echo -e "${GREEN}✅ Server container started: $SERVER_CONTAINER${NC}"
echo ""

# Wait for server to be ready
echo -e "${YELLOW}⏳ Waiting for server to be ready...${NC}"
for i in {1..30}; do
    if docker exec $SERVER_CONTAINER sh -c "curl -k https://127.0.0.1:8443/ >/dev/null 2>&1"; then
        echo -e "${GREEN}✅ Server is responding!${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}❌ Server failed to start within 30 seconds${NC}"
        docker logs $SERVER_CONTAINER
        docker rm -f $SERVER_CONTAINER
        exit 1
    fi
    sleep 1
done
echo ""

echo -e "${CYAN}🌐 Server Information:${NC}"
echo "• Container: $SERVER_CONTAINER"
echo "• Binding: 0.0.0.0:8443 (all interfaces)"
echo "• Test URL: https://127.0.0.1:8443"
echo "• Certificate: Self-signed"
echo ""

echo -e "${BLUE}🧪 Running H2SPEC Compliance Tests${NC}"
echo "=================================================="

# Use network alias instead of IP
echo -e "${CYAN}Command: h2spec -h ht2-server -p 8443 -t -k${NC}"
echo ""

# Capture start time
START_TIME=$(date +%s)

echo -e "${PURPLE}📊 H2SPEC Test Results:${NC}"
echo "=================================================="

# Run h2spec against the server container using network (run all specs by default)
if docker run --rm --platform linux/amd64 --network h2spec-test-net \
    summerwind/h2spec:latest \
    -h ht2-server -p 8443 -t -k | tee h2spec_native_docker_results.txt; then
    EXIT_CODE=0
else
    EXIT_CODE=1
fi

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "=================================================="

# Parse and display summary (same as native script)
if [ -f "h2spec_native_docker_results.txt" ]; then
    SUMMARY=$(tail -1 h2spec_native_docker_results.txt)
    # Check if we have a proper summary line
    if echo "$SUMMARY" | grep -q "tests,.*passed.*failed"; then
        PASSED=$(echo "$SUMMARY" | grep -o '[0-9]* passed' | grep -o '[0-9]*' || echo "0")
        FAILED=$(echo "$SUMMARY" | grep -o '[0-9]* failed' | grep -o '[0-9]*' || echo "0")
        SKIPPED=$(echo "$SUMMARY" | grep -o '[0-9]* skipped' | grep -o '[0-9]*' || echo "0")
    else
        echo -e "${RED}❌ Test execution failed or was interrupted${NC}"
        echo "Error details: $SUMMARY"
        docker rm -f $SERVER_CONTAINER
        exit 1
    fi
    
    echo -e "${PURPLE}📊 DOCKERIZED NATIVE H2SPEC TEST SUMMARY${NC}"
    echo "=================================================="
    echo -e "Command executed: ${CYAN}h2spec -h ht2-server -p 8443 -t -k${NC}"
    echo -e "Results file: h2spec_native_docker_results.txt"
    echo -e "Duration: ${DURATION}s"
    echo ""
    echo -e "Summary: $SUMMARY"
    echo ""
    echo -e "${GREEN}✅ Passed: $PASSED${NC}"
    if [ "$FAILED" -gt 0 ]; then
        echo -e "${RED}❌ Failed: $FAILED${NC}"
    else
        echo -e "${GREEN}❌ Failed: $FAILED${NC}"
    fi
    echo -e "${YELLOW}⏭️  Skipped: $SKIPPED${NC}"
    
    if [ "$FAILED" -eq 0 ] && [ "$PASSED" -gt 0 ]; then
        TOTAL_TESTS=$((PASSED + SKIPPED))
        if [ "$TOTAL_TESTS" -gt 0 ]; then
            COMPLIANCE_RATE=$(( (PASSED * 100) / TOTAL_TESTS ))
            echo -e "${GREEN}🎯 Compliance Rate: ${COMPLIANCE_RATE}%${NC}"
        fi
        echo ""
        echo -e "${GREEN}🏆 PERFECT HTTP/2 PROTOCOL COMPLIANCE!${NC}"
        echo -e "${GREEN}✨ All tests passed in Docker environment${NC}"
    else
        echo -e "${RED}⚠️  HTTP/2 compliance issues detected${NC}"
        echo ""
        echo -e "${RED}❌ SOME TESTS FAILED${NC}"
        
        echo ""
        echo -e "${RED}🔍 FAILED TESTS DETAILS:${NC}"
        echo "=================================================="
        grep -A 3 -B 1 "×" h2spec_native_docker_results.txt 2>/dev/null || echo "No specific failures found in output"
    fi
else
    echo -e "${RED}❌ No results file found${NC}"
    EXIT_CODE=1
fi

echo ""
echo -e "${BLUE}📋 TEST VERIFICATION DETAILS:${NC}"
echo "=================================================="
echo "• H2SPEC Version: Latest (summerwind/h2spec:latest)"
echo "• Test Suite: Complete RFC 7540 & RFC 7541 compliance"
echo "• Server Binary: Built from examples/h2spec_server.cr"
echo "• Environment: Docker containers (deterministic)"
echo "• Modifications: None - pure h2spec binary execution"
echo "• Transparency: Full unmodified test suite output"
echo "• Results File: h2spec_native_docker_results.txt"

echo ""
echo -e "${BLUE}🔗 ADDITIONAL INFORMATION:${NC}"
echo "• For skipped test explanation, see README.md"
echo "• For unit test coverage details, see spec/unit/ directory"
echo "• For H2SPEC source code, see: https://github.com/summerwind/h2spec"

echo ""
echo "=================================================="

# Cleanup
echo -e "${BLUE}🧹 Cleaning up...${NC}"
docker rm -f $SERVER_CONTAINER > /dev/null 2>&1 || true
docker network rm h2spec-test-net > /dev/null 2>&1 || true

exit $EXIT_CODE