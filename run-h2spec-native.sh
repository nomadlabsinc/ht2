#!/bin/bash

# Native H2SPEC Test Runner - Direct binary execution
# Runs the actual h2spec binary against our built server for maximum transparency
# Usage: ./run-h2spec-native.sh [--verbose] [--keep-server]

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

echo -e "${BLUE}🔧 Native H2SPEC Test Runner${NC}"
echo "=================================================="
echo "Running unmodified h2spec binary against built ht2 server"
echo "This provides the most transparent compliance testing possible."
echo ""

SERVER_PID=""

# Cleanup function
cleanup() {
    if [[ -n "$SERVER_PID" ]] && [[ "$KEEP_SERVER" != "true" ]]; then
        if [[ "$VERBOSE" == "true" ]]; then
            echo -e "${YELLOW}🔪 Stopping server (PID: $SERVER_PID)...${NC}"
        fi
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    
    # Clean up any test certificates
    rm -f server.crt server.key 2>/dev/null || true
}

# Set trap for cleanup
trap cleanup EXIT

# Check if h2spec is installed
echo -e "${BLUE}🔍 Checking h2spec installation...${NC}"
if ! command -v h2spec &> /dev/null; then
    echo -e "${YELLOW}⚠️  h2spec not found, installing...${NC}"
    
    # Detect architecture
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            H2SPEC_ARCH="amd64"
            ;;
        aarch64|arm64)
            H2SPEC_ARCH="arm64"
            ;;
        *)
            echo -e "${RED}❌ Unsupported architecture: $ARCH${NC}"
            echo "Please install h2spec manually from: https://github.com/summerwind/h2spec/releases"
            exit 1
            ;;
    esac
    
    # Download and install h2spec
    echo -e "${BLUE}📥 Downloading h2spec for $ARCH...${NC}"
    curl -L "https://github.com/summerwind/h2spec/releases/download/v2.6.0/h2spec_linux_${H2SPEC_ARCH}.tar.gz" -o h2spec.tar.gz
    tar -xzf h2spec.tar.gz
    chmod +x h2spec
    
    # Use local binary
    H2SPEC_CMD="./h2spec"
    
    echo -e "${GREEN}✅ h2spec downloaded and ready${NC}"
    rm h2spec.tar.gz
else
    H2SPEC_CMD="h2spec"
    echo -e "${GREEN}✅ h2spec found: $(which h2spec)${NC}"
fi

echo ""

# Verify h2spec version
echo -e "${BLUE}📋 H2SPEC Version Information:${NC}"
$H2SPEC_CMD --version
echo ""

# Build the server
echo -e "${BLUE}🏗️  Building ht2 server...${NC}"
if [[ "$VERBOSE" == "true" ]]; then
    crystal build examples/h2spec_server.cr -o h2spec_server --release
else
    crystal build examples/h2spec_server.cr -o h2spec_server --release > /dev/null 2>&1
fi
echo -e "${GREEN}✅ Server built successfully${NC}"
echo ""

# Generate test certificates
echo -e "${BLUE}🔐 Generating test certificates...${NC}"
openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt \
    -days 365 -nodes -subj "/CN=localhost" > /dev/null 2>&1
echo -e "${GREEN}✅ Certificates generated${NC}"
echo ""

# Start the server
echo -e "${BLUE}🚀 Starting ht2 HTTP/2 server...${NC}"
if [[ "$VERBOSE" == "true" ]]; then
    echo "Server command: ./h2spec_server --host 0.0.0.0 --port 8443"
    ./h2spec_server --host 0.0.0.0 --port 8443 &
    SERVER_PID=$!
    echo "Server started with PID: $SERVER_PID"
else
    ./h2spec_server --host 0.0.0.0 --port 8443 > server.log 2>&1 &
    SERVER_PID=$!
fi

echo -e "${GREEN}✅ Server started (PID: $SERVER_PID)${NC}"
echo ""

# Wait for server to be ready
echo -e "${YELLOW}⏳ Waiting for server to be ready...${NC}"
for i in {1..30}; do
    # Try both IPv4 and IPv6
    if curl -k https://127.0.0.1:8443/ >/dev/null 2>&1 || curl -k https://localhost:8443/ >/dev/null 2>&1; then
        echo -e "${GREEN}✅ Server is responding!${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}❌ Server failed to start within 30 seconds${NC}"
        if [[ "$VERBOSE" == "true" ]] && [[ -f "server.log" ]]; then
            echo "Server logs:"
            cat server.log
        fi
        exit 1
    fi
    sleep 1
done
echo ""

# Show server info
echo -e "${CYAN}🌐 Server Information:${NC}"
echo "• Binding: 0.0.0.0:8443 (all interfaces)"
echo "• Test URL: https://127.0.0.1:8443"
echo "• Certificate: Self-signed (server.crt)"
echo "• Process ID: $SERVER_PID"
echo "• Log file: server.log"
echo ""

# Run H2SPEC tests
echo -e "${BLUE}🧪 Running H2SPEC Compliance Tests${NC}"
echo "=================================================="
echo -e "${CYAN}Command: $H2SPEC_CMD -h 127.0.0.1 -p 8443 -t -k${NC}"
echo ""

# Capture start time
START_TIME=$(date +%s)

# Run h2spec and capture output
echo -e "${PURPLE}📊 H2SPEC Test Results:${NC}"
echo "=================================================="

if $H2SPEC_CMD -h 127.0.0.1 -p 8443 -t -k | tee h2spec_native_results.txt; then
    EXIT_CODE=0
else
    EXIT_CODE=1
fi

# Calculate duration
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "=================================================="

# Parse and display summary
if [ -f "h2spec_native_results.txt" ]; then
    SUMMARY=$(tail -1 h2spec_native_results.txt)
    # Check if we have a proper summary line
    if echo "$SUMMARY" | grep -q "tests,.*passed.*failed"; then
        PASSED=$(echo "$SUMMARY" | grep -o '[0-9]* passed' | grep -o '[0-9]*' || echo "0")
        FAILED=$(echo "$SUMMARY" | grep -o '[0-9]* failed' | grep -o '[0-9]*' || echo "0")
        SKIPPED=$(echo "$SUMMARY" | grep -o '[0-9]* skipped' | grep -o '[0-9]*' || echo "0")
    else
        # Handle error cases
        echo -e "${RED}❌ Test execution failed or was interrupted${NC}"
        echo "Error details: $SUMMARY"
        exit 1
    fi
    
    echo -e "${PURPLE}📊 NATIVE H2SPEC TEST SUMMARY${NC}"
    echo "=================================================="
    echo -e "Command executed: ${CYAN}$H2SPEC_CMD -h 127.0.0.1 -p 8443 -t -k${NC}"
    echo -e "Results file: h2spec_native_results.txt"
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
        echo -e "${GREEN}✨ All tests passed with unmodified h2spec binary${NC}"
    else
        echo -e "${RED}⚠️  HTTP/2 compliance issues detected${NC}"
        echo ""
        echo -e "${RED}❌ SOME TESTS FAILED${NC}"
        
        if [[ "$VERBOSE" == "true" ]]; then
            echo ""
            echo -e "${RED}🔍 FAILED TESTS DETAILS:${NC}"
            echo "=================================================="
            grep -A 3 -B 1 "×" h2spec_native_results.txt 2>/dev/null || echo "No specific failures found in output"
        fi
    fi
else
    echo -e "${RED}❌ No results file found${NC}"
    EXIT_CODE=1
fi

echo ""
echo -e "${BLUE}📋 TEST VERIFICATION DETAILS:${NC}"
echo "=================================================="
echo "• H2SPEC Version: $($H2SPEC_CMD --version | head -1)"
echo "• Test Suite: Complete RFC 7540 & RFC 7541 compliance"
echo "• Server Binary: Built from examples/h2spec_server.cr"
echo "• Modifications: None - pure h2spec binary execution"
echo "• Transparency: Full unmodified test suite output"
echo "• Results File: h2spec_native_results.txt"

if [[ "$KEEP_SERVER" == "true" ]]; then
    echo ""
    echo -e "${CYAN}🔄 Server kept running for manual testing:${NC}"
    echo "• Binding: 0.0.0.0:8443"
    echo "• Test URL: https://127.0.0.1:8443"
    echo "• PID: $SERVER_PID" 
    echo "• To stop: kill $SERVER_PID"
    echo "• Logs: tail -f server.log"
else
    echo "• Server: Will be stopped automatically"
fi

echo ""
echo -e "${BLUE}🔗 ADDITIONAL INFORMATION:${NC}"
echo "• For skipped test explanation, see README.md"
echo "• For unit test coverage details, see spec/unit/ directory"
echo "• For H2SPEC source code, see: https://github.com/summerwind/h2spec"

echo ""
echo "=================================================="

exit $EXIT_CODE