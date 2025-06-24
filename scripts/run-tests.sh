#!/bin/bash
set -euo pipefail

# Test runner script with parallelization support
SUITE=${1:-all}
PARALLEL_JOBS=${CRYSTAL_WORKERS:-4}

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "Running test suite: $SUITE with $PARALLEL_JOBS parallel jobs"

# Function to run a test file
run_test() {
    local test_file=$1
    local output_file="/tmp/test_$(basename $test_file).out"
    
    # Set Crystal cache dir to avoid conflicts
    export CRYSTAL_CACHE_DIR="/tmp/.crystal-$$-$(basename $test_file)"
    mkdir -p "$CRYSTAL_CACHE_DIR"
    
    if timeout 60 crystal spec --no-color "$test_file" > "$output_file" 2>&1; then
        echo -e "${GREEN}✓${NC} $test_file"
        rm -rf "$CRYSTAL_CACHE_DIR"
        return 0
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo -e "${RED}✗ TIMEOUT${NC} $test_file"
        else
            echo -e "${RED}✗${NC} $test_file"
        fi
        cat "$output_file" | head -50
        rm -rf "$CRYSTAL_CACHE_DIR"
        return 1
    fi
}

export -f run_test
export GREEN RED NC

# Define test suites
case "$SUITE" in
    unit)
        TEST_FILES=$(find spec -name "*_spec.cr" \
            -not -path "*/integration/*" \
            -not -name "*integration*" \
            -not -name "cve_*" \
            -not -name "server_spec.cr" | sort)
        ;;
    integration)
        TEST_FILES=$(find spec -name "*integration*_spec.cr" \
            -not -name "cve_*" | sort)
        ;;
    security)
        TEST_FILES=$(find spec -name "cve_*_spec.cr" -o \
            -name "security_*_spec.cr" -o \
            -name "rapid_reset_*_spec.cr" | sort)
        ;;
    performance)
        TEST_FILES=$(find spec -name "*performance*_spec.cr" -o \
            -name "*metrics*_spec.cr" -o \
            -name "*buffer*_spec.cr" | sort)
        ;;
    h2c)
        TEST_FILES=$(find spec -name "*h2c*_spec.cr" | sort)
        ;;
    all)
        TEST_FILES=$(find spec -name "*_spec.cr" | sort)
        ;;
    *)
        echo "Unknown test suite: $SUITE"
        exit 1
        ;;
esac

# Count total tests
TOTAL_TESTS=$(echo "$TEST_FILES" | wc -w)
echo "Found $TOTAL_TESTS test files"

# Run tests in parallel
START_TIME=$(date +%s)

if [ "$PARALLEL_TESTS" = "true" ] && [ "$TOTAL_TESTS" -gt 1 ]; then
    echo "Running tests in parallel..."
    echo "$TEST_FILES" | tr ' ' '\n' | \
        parallel -j "$PARALLEL_JOBS" --line-buffer run_test {}
    RESULT=$?
else
    echo "Running tests sequentially..."
    FAILED=0
    for test_file in $TEST_FILES; do
        if ! run_test "$test_file"; then
            FAILED=$((FAILED + 1))
        fi
    done
    RESULT=$FAILED
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "Test suite completed in ${DURATION}s"

if [ $RESULT -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi