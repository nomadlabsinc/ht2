# H2spec Compliance Testing

This document describes how to run h2spec compliance tests for the HT2 HTTP/2 server implementation.

## Current Compliance Status

**144/146 tests passing (98.6% compliance)**

### Known Issues

Two tests have issues when running the full suite:
- **6.5.3/1**: "Sends multiple values of SETTINGS_INITIAL_WINDOW_SIZE" - h2spec probe limitation
- **6.9.2/2**: "Sends a SETTINGS frame for window size to be negative" - Appears to be skipped

These failures occur due to h2spec's connection reuse after running 140+ tests. When run in isolation, all tests pass 100%.

## Running H2spec Tests Locally

### Quick Start

The easiest way to run h2spec tests is using the provided Makefile targets:

```bash
# Run split h2spec tests (recommended - matches CI)
make h2spec

# Run only Part 1 (sections 3-5: DATA, SETTINGS, PING)
make h2spec-part1

# Run only Part 2 (sections 6-8: GOAWAY, WINDOW_UPDATE, CONTINUATION)
make h2spec-part2

# Run full test suite (may have probe failures)
make h2spec-full

# Clean up h2spec containers and results
make h2spec-clean
```

### Using the Script

Alternatively, use the convenience script:

```bash
./scripts/run-h2spec-docker.sh
```

This script will:
1. Build the h2spec server Docker image
2. Start the server
3. Run Part 1 tests (sections 3-5)
4. Run Part 2 tests (sections 6-8)
5. Display results and clean up

### Using Docker Compose Directly

For more control, use Docker Compose directly:

```bash
# Build the server image
docker build -f Dockerfile.h2spec -t ht2-h2spec .

# Run both parts
docker-compose -f docker-compose.h2spec.yml up h2spec-server h2spec-part1 h2spec-part2

# View results
cat h2spec-results/part1_results.txt
cat h2spec-results/part2_results.txt
```

### Manual Testing

To run h2spec tests manually:

1. Start the h2spec server:
```bash
docker run -d --name h2spec-server -p 8443:8443 ht2-h2spec ./h2spec_server --host 0.0.0.0
```

2. Run h2spec against it:
```bash
# Part 1
docker run --rm -v $PWD:/work summerwind/h2spec:2.6.0 \
  -h host.docker.internal -p 8443 -t -k http2/3 http2/4 http2/5

# Part 2
docker run --rm -v $PWD:/work summerwind/h2spec:2.6.0 \
  -h host.docker.internal -p 8443 -t -k http2/6 http2/7 http2/8
```

3. Clean up:
```bash
docker stop h2spec-server && docker rm h2spec-server
```

## Test Sections

The tests are split to prevent h2spec probe failures:

### Part 1 (Sections 3-5)
- **Section 3**: DATA frames
- **Section 4**: HTTP Message Exchanges  
- **Section 5**: HPACK

### Part 2 (Sections 6-8)
- **Section 6**: Frame Definitions (includes problematic tests)
- **Section 7**: Error Codes
- **Section 8**: HTTP Message Exchanges

## CI Integration

In CI, tests run on `ubicloud-standard-4` instances with the same split configuration. See `.github/workflows/h2spec.yml` for details.

## Troubleshooting

### Server won't start
- Check if port 8443 is already in use
- Ensure Docker is running
- Check Docker logs: `docker-compose -f docker-compose.h2spec.yml logs h2spec-server`

### Tests fail unexpectedly
- Ensure you're using the split test approach
- Check h2spec-results/*.txt for detailed error messages
- Try running tests in isolation

### Different results between local and CI
- Ensure you're using the same h2spec version (2.6.0)
- Check that you're running tests in split mode
- Verify the server image is up to date