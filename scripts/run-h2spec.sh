#!/bin/bash

# H2SPEC Test Runner - Clean output for developers
# Usage: ./scripts/run-h2spec.sh [--verbose]

set -e

VERBOSE=false
if [[ "$1" == "--verbose" ]]; then
    VERBOSE=true
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}🧪 H2SPEC HTTP/2 Protocol Compliance Test Suite${NC}"
echo "=================================================="
echo ""

# Cleanup function
cleanup() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${YELLOW}🧹 Cleaning up containers and networks...${NC}"
    fi
    docker rm -f ht2-h2spec-server 2>/dev/null || true
    docker network rm h2spec-test-net 2>/dev/null || true
}

# Set trap for cleanup
trap cleanup EXIT

# Build image
echo -e "${BLUE}📦 Building H2SPEC test image...${NC}"
if [[ "$VERBOSE" == "true" ]]; then
    docker build -f Dockerfile.h2spec -t ht2-h2spec .
else
    docker build -f Dockerfile.h2spec -t ht2-h2spec . > /dev/null 2>&1
fi
echo -e "${GREEN}✅ Image built successfully${NC}"
echo ""

# Create network
echo -e "${BLUE}🌐 Setting up test network...${NC}"
docker network create h2spec-test-net > /dev/null 2>&1

# Start server
echo -e "${BLUE}🚀 Starting ht2 HTTP/2 server...${NC}"
if [[ "$VERBOSE" == "true" ]]; then
    docker run -d --name ht2-h2spec-server --network h2spec-test-net \
        -e HT2_LOG_LEVEL=ERROR \
        ht2-h2spec ./h2spec_server --host 0.0.0.0
else
    docker run -d --name ht2-h2spec-server --network h2spec-test-net \
        -e HT2_LOG_LEVEL=ERROR \
        ht2-h2spec ./h2spec_server --host 0.0.0.0 > /dev/null 2>&1
fi

# Wait for server to be ready
echo -e "${YELLOW}⏳ Waiting for server to be ready...${NC}"
for i in {1..30}; do
    if docker exec ht2-h2spec-server curl -k https://localhost:8443/ >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Server is ready!${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}❌ Server failed to start${NC}"
        if [[ "$VERBOSE" == "true" ]]; then
            docker logs ht2-h2spec-server
        fi
        exit 1
    fi
    sleep 1
done
echo ""

# Run H2SPEC tests
echo -e "${BLUE}🧪 Running H2SPEC compliance tests (146 tests)...${NC}"
echo "=================================================="
echo ""

# Run h2spec with clean output
if docker run --rm --network h2spec-test-net \
    summerwind/h2spec:2.6.0 \
    -h ht2-h2spec-server -p 8443 -t -k \
    2>/dev/null | tee h2spec_results.txt; then
    
    EXIT_CODE=0
else
    EXIT_CODE=1
fi

echo ""
echo "=================================================="

# Parse and display results
if [ -f "h2spec_results.txt" ]; then
    SUMMARY=$(tail -1 h2spec_results.txt)
    PASSED=$(echo "$SUMMARY" | grep -o '[0-9]* passed' | grep -o '[0-9]*' || echo "0")
    FAILED=$(echo "$SUMMARY" | grep -o '[0-9]* failed' | grep -o '[0-9]*' || echo "0")
    SKIPPED=$(echo "$SUMMARY" | grep -o '[0-9]* skipped' | grep -o '[0-9]*' || echo "0")
    
    echo -e "${BLUE}📊 TEST RESULTS SUMMARY${NC}"
    echo "=================================================="
    echo -e "Summary: $SUMMARY"
    echo -e "${GREEN}✅ Passed: $PASSED${NC}"
    if [ "$FAILED" -gt 0 ]; then
        echo -e "${RED}❌ Failed: $FAILED${NC}"
    else
        echo -e "${GREEN}❌ Failed: $FAILED${NC}"
    fi
    echo -e "${YELLOW}⏭️  Skipped: $SKIPPED${NC}"
    
    if [ "$FAILED" -eq 0 ]; then
        COMPLIANCE_RATE=$(( (PASSED * 100) / (PASSED + SKIPPED) ))
        echo -e "${GREEN}🎉 Compliance Rate: ${COMPLIANCE_RATE}% (Perfect!)${NC}"
        echo ""
        echo -e "${GREEN}🏆 ALL TESTS PASSED - HTTP/2 PROTOCOL COMPLIANT!${NC}"
    else
        echo -e "${RED}⚠️  HTTP/2 compliance issues detected${NC}"
        echo ""
        echo -e "${RED}❌ SOME TESTS FAILED - REVIEW REQUIRED${NC}"
        
        if [[ "$VERBOSE" == "true" ]] && [ -f "h2spec_results.txt" ]; then
            echo ""
            echo -e "${RED}🔍 FAILED TESTS:${NC}"
            echo "=================================================="
            grep -A 2 -B 1 "×" h2spec_results.txt || echo "No specific failures found in output"
        fi
    fi
else
    echo -e "${RED}❌ No results file found${NC}"
    EXIT_CODE=1
fi

echo ""
echo -e "${BLUE}📋 NOTES:${NC}"
echo "• Full results saved to: h2spec_results.txt"
echo "• Test 6.9.2/2 is intentionally skipped (proven compliant via unit tests)"
echo "• For details on the skipped test, see README.md"

if [[ "$VERBOSE" != "true" ]]; then
    echo "• Run with --verbose flag for detailed output and failure analysis"
fi

echo ""
echo "=================================================="

exit $EXIT_CODE