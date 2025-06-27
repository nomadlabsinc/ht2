#!/bin/bash

# Just run the full h2spec suite and grep for the specific test
echo "Running h2spec and looking for test 6.10/1..."

# Check existing results
echo "=== From previous results ==="
grep -B5 -A10 "6.10. CONTINUATION" h2spec_results_detailed.txt | grep -A10 "× 1:"

# The key insight: this test ONLY times out, all others either pass or fail quickly
# This suggests the server is waiting for something that never comes

echo -e "\n=== Key observation ==="
echo "Test 6.10/1 is the ONLY test that times out (takes >1 second)"
echo "All other tests complete quickly with pass/fail"
echo "This suggests the server is stuck waiting for more data"

# Check what makes this test unique
echo -e "\n=== What's special about test 6.10/1? ==="
echo "It's in section 6 (Frame Definitions), not section 3 (general protocol)"
echo "Section 3.10 CONTINUATION tests pass fine"
echo "This suggests it might test a specific edge case"

# My hypothesis
echo -e "\n=== Hypothesis ==="
echo "The h2spec test might be:"
echo "1. Sending HEADERS without END_HEADERS"
echo "2. Sending multiple CONTINUATION frames"  
echo "3. The last CONTINUATION has END_HEADERS"
echo "4. BUT the headers might be incomplete or invalid"
echo "5. Server waits forever for valid headers or more frames"