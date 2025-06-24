# HT2 Testing Guide

## Test Environment Setup

HT2's test suite includes integration tests with various HTTP/2 clients to ensure broad compatibility. To run all tests, you need to install additional dependencies.

### Quick Setup

```bash
# Install all test dependencies
./bin/setup-test-env.sh

# Verify dependencies are installed
./bin/verify-test-deps.sh
```

### Required Dependencies

The following tools are required for the complete test suite:

1. **curl** - For basic HTTP/2 testing
2. **Python 3** with:
   - `httpx` - Python HTTP/2 client library
   - `h2spec` - HTTP/2 conformance testing tool
3. **Node.js** - For testing with Node's built-in HTTP/2 client

### Docker Testing

All dependencies are pre-installed in the Docker test environment:

```bash
# Run tests in Docker (recommended for CI parity)
docker-compose run test

# Run tests with Crystal 1.15
docker-compose run test-1.15

# Run tests with Crystal 1.16
docker-compose run test-1.16
```

### Running Tests

```bash
# Run all tests
crystal spec

# Run specific test file
crystal spec spec/integration/curl_http2_integration_spec.cr

# Run with timing information
crystal spec -t

# Run CI checks (format, lint, build, test)
./bin/ci-check.sh
```

### Pending Tests

Some tests are marked as pending because they test features that are planned but not yet implemented:

- **Connection Pooling** (21 tests) - Advanced connection management features
- **HTTP Client Methods** (5 tests) - High-level HTTP method helpers
- **H2C Features** (4 tests) - HTTP/2 cleartext advanced features
- **Server Push** (1 test) - HTTP/2 server push (optional feature)
- **External Tool Integration** (8 tests) - Now enabled with proper dependencies

With the Docker environment or proper local setup, all external tool integration tests will run successfully.

### Troubleshooting

If tests are hanging:
1. Check for servers not closing properly in integration tests
2. Look for blocking operations without timeouts
3. The test suite has a 4-minute global timeout to prevent indefinite hangs

If external tool tests fail:
1. Run `./bin/verify-test-deps.sh` to check dependencies
2. Use Docker environment for guaranteed compatibility
3. Check that h2spec is installed correctly