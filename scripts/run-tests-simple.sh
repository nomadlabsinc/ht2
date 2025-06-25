#!/bin/bash
set -euo pipefail

# Simple test runner that runs tests sequentially but fast
SUITE=${1:-all}

echo "Running test suite: $SUITE"

# Define test suites
case "$SUITE" in
    unit)
        PATTERN="spec/**/*_spec.cr"
        EXCLUDE="integration|cve_|server_spec"
        ;;
    integration)
        PATTERN="spec/**/*integration*_spec.cr"
        EXCLUDE="cve_"
        ;;
    security)
        PATTERN="spec/**/cve_*_spec.cr spec/**/security_*_spec.cr spec/**/rapid_reset_*_spec.cr"
        EXCLUDE="NONE"
        ;;
    h2c)
        PATTERN="spec/**/*h2c*_spec.cr"
        EXCLUDE="NONE"
        ;;
    all)
        PATTERN="spec/**/*_spec.cr"
        EXCLUDE="NONE"
        ;;
    *)
        echo "Unknown test suite: $SUITE"
        exit 1
        ;;
esac

# Run tests
START_TIME=$(date +%s)

if [ "$EXCLUDE" = "NONE" ]; then
    crystal spec $PATTERN --no-color
else
    # Find files matching pattern but not exclude
    TEST_FILES=$(find spec -name "*_spec.cr" | grep -v -E "$EXCLUDE" | sort)
    crystal spec $TEST_FILES --no-color
fi

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "Test suite completed in ${DURATION}s"