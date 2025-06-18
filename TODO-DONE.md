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

- [x] **Make increment calculation more dynamic** - Commit: ab57cbc
  - Consider multiple factors: burst state, stall history, rate variance
  - Predictive consumption calculation using weighted averages
  - Dynamic safety margins based on variance
  - Adaptive response to high RTT and packet loss

## ✅ Per-IP Rate Limiting

- [x] **Add per-IP rate limiting for stream creation** - Commit: ff3fd09
  - Modified Connection class to accept optional client_ip parameter
  - Updated Server to extract client IP from TCPSocket.remote_address.address
  - Use client IP as connection ID for rate limiting tracking
  - Maintains backward compatibility with object-based IDs when IP not available
  - Integrates seamlessly with existing RapidResetProtection infrastructure

## ✅ Dynamic Settings Updates

- [x] **Implement graceful handling of SETTINGS changes mid-connection** - Current Branch
  - Added apply_remote_settings method to validate and apply settings atomically
  - Implement proper error handling with GOAWAY on invalid settings
  - Added overflow protection for INITIAL_WINDOW_SIZE updates
  - Track applied settings for feedback and debugging

- [x] **Add validation for settings value ranges** - Current Branch
  - Centralized validation in validate_setting method
  - Validate ENABLE_PUSH (0 or 1)
  - Validate INITIAL_WINDOW_SIZE (max 0x7FFFFFFF)
  - Validate MAX_FRAME_SIZE (16384-16777215)
  - Proper error codes for each validation failure

- [x] **Implement settings negotiation feedback** - Current Branch
  - Added applied_settings tracking to monitor what settings were successfully applied
  - Added update_settings method for dynamic local settings updates
  - Support for pending settings with ACK timeout handling
  - Proper SETTINGS ACK queue management for concurrent updates

## ✅ Connection Pooling & HTTP/2 Client

- [x] **Implement HTTP/2 client with connection pooling** - Commit: TBD
  - Full HTTP/2 client implementation supporting GET, POST, PUT, DELETE, HEAD methods
  - Connection pooling with configurable limits per host
  - Health validation and automatic removal of unhealthy connections
  - Idle connection timeout and cleanup
  - Connection warm-up for pre-establishing connections
  - Graceful connection draining with stream completion waiting
  - Thread-safe connection management with mutex protection
  - Automatic retry with new connection on failure
  - TLS support with ALPN negotiation verification
  - Response handling with headers and body accumulation

## ✅ Performance - Stream Processing

- [x] **Implement bounded worker pool for stream handling** - Commit: aa3e9e1
  - Created WorkerPool class with configurable max workers and queue size
  - Prevents unbounded fiber creation and provides backpressure
  - Integrated into Server to handle stream processing with concurrency limits
  - Returns 503 Service Unavailable when worker pool is full
  - Provides monitoring methods for active count and queue depth
  - Graceful shutdown waits for all tasks to complete
  - Thread-safe with atomic counters and mutex protection
  - Comprehensive test coverage for all functionality

- [x] **Add backpressure mechanisms for slow consumers** - Commit: d1b0ad4
  - Created BackpressureManager class to track write pressure at connection and stream levels
  - Implemented high/low watermark system for automatic pause/resume of writes
  - Added per-stream pressure tracking with 1/4 of total buffer allocation per stream
  - Integrated backpressure checks into Connection#send_frame with timeout support
  - Added chunked data sending support in Stream for large payloads
  - Enhanced WorkerPool with try_submit, can_accept?, and utilization methods
  - Comprehensive test coverage for all backpressure scenarios

## ✅ Performance - Memory Optimization

- [x] **Optimize memory allocation for frame processing** - Commit: fbbd5e7
  - Implemented BufferPool class for reusable byte buffers
  - Added buffer pooling to frame serialization (Frame#to_bytes)
  - Integrated buffer pool into Connection read/write loops
  - Created FrameCache for frequently used frames (SETTINGS ACK, PING ACK)
  - Optimized HPACK encoder to support external IO buffers
  - Enhanced Huffman encoding to reuse buffers
  - Reduced allocations in frame processing hot paths
  - Added performance benchmarks to measure improvements

## ✅ Performance - I/O Optimizations

- [x] **Implement zero-copy frame forwarding where possible** - Current Branch
  - Created ZeroCopy module with write_frame and forward_data_frame methods
  - Added zero-copy write methods to Frame base class (write_to)
  - Optimized DataFrame to use zero-copy for non-padded frames
  - Updated Connection to use zero-copy path for DATA frames
  - Implemented BufferList for accumulating data without copying
  - Added comprehensive test coverage for all zero-copy functionality
  - Reduces memory allocations and copies for high-throughput scenarios