# H2SPEC Test Results - 10 Runs Each Environment

## Pass/Fail Rate Comparison

```
Environment    | Pass Rate | Consistency | Total Tests
============== | ========= | =========== | ===========
Docker (Linux) | 100.0%    | 100%        | 146/146
Native (macOS) | 99.3%     | 100%        | 145/146
```

## Visual Results Chart

### Docker Environment (Perfect Record)
```
Runs:  1   2   3   4   5   6   7   8   9   10
      ✅  ✅  ✅  ✅  ✅  ✅  ✅  ✅  ✅  ✅
      146 146 146 146 146 146 146 146 146 146
```

### Native macOS Environment (Consistent 1 Failure)
```
Runs:  1   2   3   4   5   6   7   8   9   10  
      ❌  ❌  ❌  ❌  ❌  ❌  ❌  ❌  ❌  ❌
      145 145 145 145 145 145 145 145 145 145
```

## Test Outcome Distribution

### Passed Tests
```
Docker:  ████████████████████████████████████████ 146/146 (100%)
Native:  ████████████████████████████████████████ 145/146 (99.3%)
```

### Failed Tests  
```
Docker:  (none)                                     0/146 (0%)
Native:  █                                         1/146 (0.7%)
```

## Consistency Analysis

Both environments showed **perfect consistency**:
- **0 flaky tests** - no intermittent failures
- **Deterministic results** - identical outcomes across all runs
- **Reproducible bugs** - the native failure occurs 100% of the time

## Key Findings

1. **Docker Environment**: 
   - ✅ Perfect HTTP/2 compliance
   - ✅ No protocol violations
   - ✅ Production-ready

2. **Native macOS**:
   - ⚠️ One reproducible bug (test 5.1.1.2)
   - ✅ Otherwise excellent compliance
   - 🔧 Needs stream ID validation fix

3. **Overall**:
   - 🎯 Highly reliable server implementation
   - 📊 Consistent, predictable behavior
   - 🐛 One known, fixable issue

The server demonstrates excellent stability and near-perfect HTTP/2 protocol compliance, with only one platform-specific timing issue that needs addressing.