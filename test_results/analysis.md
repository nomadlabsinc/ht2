# H2SPEC Test Results Analysis

## Summary

Ran h2spec test suite 10 times in each environment to analyze consistency and reliability.

## Results

### Docker Environment (Linux Container)
- **All 10 runs**: 146/146 tests passed (100% success rate)
- **Failed tests**: None
- **Skipped tests**: None
- **Consistency**: Perfect - identical results across all runs

### Native macOS Environment  
- **All 10 runs**: 145/146 tests passed (99.3% success rate)
- **Failed tests**: 1 (consistently test 5.1.1.2)
- **Skipped tests**: None
- **Consistency**: Perfect - identical results across all runs

### Failing Test Details

**Test 5.1.1.2**: "Sends stream identifier that is numerically smaller than previous"
- **Status**: Fails consistently on macOS native, passes consistently in Docker
- **Issue**: Stream ID validation bug related to PRIORITY frame handling
- **Expected**: GOAWAY Frame (Error Code: PROTOCOL_ERROR) + Connection closed
- **Actual**: DATA Frame (length:185, flags:0x01, stream_id:5)

## Analysis

### Environment Differences
1. **Docker**: Virtualized network stack provides different timing characteristics that mask the race condition
2. **Native macOS**: Direct network access exposes the timing-sensitive bug in stream ID validation

### Reliability
- Both environments show **100% consistency** across 10 runs
- No flaky tests or intermittent failures
- Results are deterministic and reproducible

### Protocol Compliance
- **Docker**: Perfect HTTP/2 compliance (146/146)
- **Native**: Near-perfect compliance (145/146) with one known bug

## Root Cause

The failing test indicates a bug in the server's stream ID validation logic when PRIORITY frames create idle streams. The server incorrectly allows HEADERS frames with stream IDs lower than previously seen PRIORITY frame stream IDs.

## Recommendations

1. **Fix stream ID validation** to properly track highest stream ID across all frame types
2. **Update `@last_stream_id`** when PRIORITY frames create idle streams
3. **Test the fix** in both environments to ensure consistency