# TODO-DONE.md

This document tracks completed features and fixes with their corresponding commit references.

## ✅ Security Improvements

### RFC Compliance
- [x] **Fix header validation to match RFC 7230 token definition** - Commit: 6379506
  - Allow uppercase letters in header names per RFC 7230
  - Validate all token characters: !#$%&'*+-.0-9A-Z^_`a-z|~
  - Convert header names to lowercase in HPACK decoder (HTTP/2 requirement)

### CVE Protections
- [x] **Add SETTINGS ACK timeout protection** - Commit: c4cbe1f
  - Implement 10-second timeout for SETTINGS acknowledgment
  - Send GOAWAY with SETTINGS_TIMEOUT error on timeout
  - Handle pending settings updates with individual timeouts
  - Prevent CVE-2024-27983 SETTINGS frame flood attacks

- [x] **Add CONTINUATION frame count limit protection** - Commit: d90053d
  - Add MAX_CONTINUATION_FRAMES limit (20 frames)
  - Track continuation frame count per header block
  - Reset count when starting new header block
  - Prevent CVE-2019-9516 0-Length Headers attacks

- [x] **Add configurable HPACK decoder max_size parameter** - Commit: 6175ffe
  - Add max_headers_size property to HPACK Decoder
  - Make it configurable via constructor parameter
  - Update from MAX_HEADER_LIST_SIZE setting dynamically
  - Prevent HPACK bomb attacks (CVE-2016-4462)

## ✅ Configuration Improvements

- [x] **Expose all HTTP/2 settings in Server constructor** - Commit: 79ba87f
  - Add header_table_size and enable_push parameters
  - Configure all 6 HTTP/2 settings via constructor
  - Allow full control over server HTTP/2 behavior
  - Maintain backward compatibility with defaults

## ✅ Previously Implemented Features

### Core HTTP/2 Implementation
- [x] HTTP/2 frame parsing and serialization
- [x] Connection preface handling
- [x] ALPN negotiation for TLS
- [x] Basic stream state management
- [x] Flow control with window updates
- [x] HPACK header compression/decompression
- [x] Priority handling
- [x] Error handling with GOAWAY and RST_STREAM

### Security Features (from commit 00e382d)
- [x] Rate limiting for SETTINGS frames (CVE-2019-9515)
- [x] Rate limiting for PING frames (CVE-2019-9512)
- [x] Rate limiting for RST_STREAM frames (CVE-2019-9514)
- [x] Rate limiting for PRIORITY frames (CVE-2019-9516)
- [x] Padding oracle protection
- [x] Frame size validation (CVE-2019-9513)
- [x] Window update overflow protection (CVE-2019-9517)
- [x] Total stream limit enforcement
- [x] Dynamic table entry limits
- [x] HPACK integer overflow protection
- [x] Consistent error messages for padding validation

## ✅ Infrastructure

- [x] **Add GitHub CI workflow** - Part of final commit
  - Run tests on multiple Crystal versions
  - Include formatting check
  - Include Ameba linting
  - Cache dependencies for faster builds

## ✅ Stream State Management & Testing

- [x] **Create comprehensive test suite for stream state transitions** - Commit: 2ac37d1
  - Test all valid state transitions per RFC 7540 Section 5.1
  - Cover edge cases like trailers and concurrent END_STREAM
  - Validate frame rejection in invalid states
  - Test PRIORITY frame handling after closure

- [x] **Ensure PRIORITY frames work after stream closure** - Commit: 2ac37d1
  - Allow PRIORITY frames for 2 seconds after stream closure
  - Track stream closure time for proper validation
  - Implement RFC 7540 compliant behavior

## ✅ Performance & Flow Control

- [x] **Implement adaptive flow control window updates** - Commit: 2ac37d1
  - Dynamic window update strategies based on consumption rate
  - Support for conservative, moderate, aggressive, and dynamic modes
  - Adapt to network conditions (RTT, packet loss)
  - Track and prevent flow control stalls
  - Implement both connection and stream-level flow control

## ✅ Security - Rapid Reset Protection

- [x] **Implement rapid reset attack protection (CVE-2023-44487)** - Commit: 2ac37d1
  - Track stream creation rates and rapid cancellations
  - Configurable rate limits for streams per second
  - Ban connections exceeding rapid reset thresholds
  - Monitor pending streams to prevent resource exhaustion
  - Provide metrics for attack pattern detection

## ✅ Comprehensive Testing

- [x] **Create comprehensive test suite for all state transitions with every frame type** - Commit: 98b6f53
  - Test all frame types (DATA, HEADERS, PRIORITY, RST_STREAM, WINDOW_UPDATE) in each state
  - Cover all valid state transitions per RFC 7540 Section 5.1
  - Validate frame rejection in invalid states
  - Test special cases like trailers, concurrent END_STREAM, and error conditions
  - Ensure PRIORITY frames work correctly after stream closure (2-second grace period)

## ✅ Enhanced Adaptive Flow Control

- [x] **Implement adaptive window update strategy based on data consumption rate** - Commit: TBD
  - Enhanced burst detection based on consumption rate patterns
  - Dynamic threshold adjustment based on variance and network conditions
  - Predictive allocation for stable consumption patterns
  - Aggressive allocation after stalls to prevent future stalls
  - Bounds checking and overflow protection

- [x] **Make increment calculation more dynamic** - Commit: TBD
  - Consider multiple factors: burst state, stall history, rate variance
  - Predictive consumption calculation using weighted averages
  - Dynamic safety margins based on variance
  - Adaptive response to high RTT and packet loss