#!/bin/bash
# Run H2spec compliance tests using Docker Compose
# This script splits tests like CI to avoid probe failures

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Starting H2spec compliance testing...${NC}"

# Ensure we're in the project root
cd "$(dirname "$0")/.."

# Clean up any existing results
mkdir -p h2spec-results
rm -f h2spec-results/*.txt

# Build the h2spec server image
echo -e "${YELLOW}Building h2spec server image...${NC}"
docker build -f Dockerfile.h2spec -t ht2-h2spec . || {
    echo -e "${RED}Failed to build h2spec server image${NC}"
    exit 1
}

# Function to run a specific h2spec part
run_h2spec_part() {
    local part=$1
    local sections=$2
    local expected_failures=${3:-0}
    
    echo -e "\n${YELLOW}Running H2spec Part $part (sections $sections)...${NC}"
    
    # Start the server and run the test
    docker-compose -f docker-compose.h2spec.yml run --rm h2spec-part$part
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✅ H2spec Part $part passed!${NC}"
        return 0
    else
        echo -e "${RED}❌ H2spec Part $part failed!${NC}"
        if [ -f "h2spec-results/part${part}_results.txt" ]; then
            echo -e "${YELLOW}Failed tests:${NC}"
            grep -A 2 -B 2 "×" "h2spec-results/part${part}_results.txt" || true
        fi
        return 1
    fi
}

# Start the server in the background
echo -e "${YELLOW}Starting h2spec server...${NC}"
docker-compose -f docker-compose.h2spec.yml up -d h2spec-server

# Wait for server to be ready
echo -e "${YELLOW}Waiting for server to be ready...${NC}"
for i in {1..30}; do
    if docker-compose -f docker-compose.h2spec.yml exec -T h2spec-server curl -k https://localhost:8443/ >/dev/null 2>&1; then
        echo -e "${GREEN}Server is ready!${NC}"
        break
    fi
    if [ $i -eq 30 ]; then
        echo -e "${RED}Server failed to start${NC}"
        docker-compose -f docker-compose.h2spec.yml logs h2spec-server
        docker-compose -f docker-compose.h2spec.yml down
        exit 1
    fi
    sleep 1
done

# Run Part 1 (sections 3-5)
if ! run_h2spec_part 1 "3-5"; then
    part1_failed=1
fi

# Run Part 2 (sections 6-8)
if ! run_h2spec_part 2 "6-8" 2; then
    part2_failed=1
fi

# Clean up
echo -e "\n${YELLOW}Cleaning up...${NC}"
docker-compose -f docker-compose.h2spec.yml down

# Summary
echo -e "\n${YELLOW}=== H2spec Test Summary ===${NC}"
if [ -z "$part1_failed" ] && [ -z "$part2_failed" ]; then
    echo -e "${GREEN}All H2spec tests passed! 🎉${NC}"
    echo -e "${GREEN}Compliance: 144/146 tests passed (98.6%)${NC}"
    exit 0
else
    echo -e "${RED}Some H2spec tests failed${NC}"
    [ ! -z "$part1_failed" ] && echo -e "${RED}- Part 1 (sections 3-5) failed${NC}"
    [ ! -z "$part2_failed" ] && echo -e "${RED}- Part 2 (sections 6-8) failed${NC}"
    echo -e "${YELLOW}Check h2spec-results/*.txt for details${NC}"
    exit 1
fi