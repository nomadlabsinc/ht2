#\!/bin/bash

# Run h2spec locally against Dockerized server
# This approach avoids Docker network issues and gives accurate results

set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "🚀 Building Docker image..."
docker build -f Dockerfile.h2spec -t ht2-h2spec . --quiet

# Clean up any existing container
docker rm -f ht2-server-h2spec 2>/dev/null || true

echo "🐳 Starting HT2 server in Docker..."
docker run -d --name ht2-server-h2spec -p 8443:8443 ht2-h2spec ./basic_server --host 0.0.0.0

# Wait for server to be ready
echo "⏳ Waiting for server to start..."
for i in {1..30}; do
    if curl -k https://localhost:8443/ >/dev/null 2>&1; then
        echo "✅ Server is ready\!"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "❌ Server failed to start"
        docker logs ht2-server-h2spec
        exit 1
    fi
    sleep 1
done

# Check if h2spec is installed
if \! command -v h2spec &> /dev/null; then
    echo "❌ h2spec not found. Please install it:"
    echo "   macOS: brew install h2spec"
    echo "   Linux: Download from https://github.com/summerwind/h2spec/releases"
    exit 1
fi

echo "🧪 Running h2spec tests..."
h2spec -h localhost -p 8443 -t -k -j h2spec_results.json | tee h2spec_results.txt

# Parse results
if [ -f h2spec_results.txt ]; then
    SUMMARY=$(tail -n 1 h2spec_results.txt)
    echo ""
    echo "📊 Test Summary:"
    echo "$SUMMARY"
    
    # Extract numbers
    TOTAL=$(echo "$SUMMARY" | grep -o '[0-9]* tests' | grep -o '[0-9]*')
    PASSED=$(echo "$SUMMARY" | grep -o '[0-9]* passed' | grep -o '[0-9]*')
    FAILED=$(echo "$SUMMARY" | grep -o '[0-9]* failed' | grep -o '[0-9]*')
    
    # Generate markdown report
    echo "# h2spec Test Results" > h2spec_results.md
    echo "" >> h2spec_results.md
    echo "## Summary" >> h2spec_results.md
    echo "" >> h2spec_results.md
    echo "- Total tests: $TOTAL" >> h2spec_results.md
    echo "- Passed: $PASSED" >> h2spec_results.md
    echo "- Failed: $FAILED" >> h2spec_results.md
    echo "- Success rate: $(( PASSED * 100 / TOTAL ))%" >> h2spec_results.md
    echo "" >> h2spec_results.md
    
    if [ "$FAILED" -gt 0 ]; then
        echo "## Failed Tests" >> h2spec_results.md
        echo "" >> h2spec_results.md
        grep -B 2 "×" h2spec_results.txt | grep -v "^--$" >> h2spec_results.md
    fi
    
    # Color output based on results
    if [ "$FAILED" -eq 0 ]; then
        echo -e "${GREEN}✅ All tests passed\!${NC}"
    else
        echo -e "${RED}❌ $FAILED tests failed${NC}"
    fi
fi

# Cleanup
echo "🧹 Cleaning up..."
docker rm -f ht2-server-h2spec

echo "✨ Done\! Results saved to:"
echo "  - h2spec_results.txt (full output)"
echo "  - h2spec_results.json (JSON format)"
echo "  - h2spec_results.md (summary)"
