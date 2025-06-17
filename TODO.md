# HT2 HTTP/2 Server - TODO List

This document consolidates all remaining tasks for the HT2 HTTP/2 server implementation.

## 🔧 RFC Compliance Issues

### Stream State Management
- [ ] Create comprehensive test suite for all state transitions with every frame type
- [ ] Consider refactoring to a more formal state machine pattern for better maintainability
- [ ] Ensure PRIORITY frames can be processed for a short time after stream closure (per RFC 7540 Section 5.1)

### Flow Control
- [ ] Implement adaptive window update strategy based on data consumption rate
- [ ] Make increment calculation more dynamic instead of fixed threshold
- [ ] Track data consumption over time to make better-informed window update decisions

### Error Handling
- [ ] Review all ConnectionError and StreamError exceptions to ensure most specific ErrorCode is used
- [ ] Add more comprehensive GOAWAY handling tests
- [ ] Ensure proper error codes for edge cases (e.g., FRAME_SIZE_ERROR vs PROTOCOL_ERROR)

## 🔒 Security Enhancements

### Rapid Reset Defense (CVE-2023-44487)
- [ ] Check stream limits *before* allocating Stream objects to prevent resource allocation
- [ ] Implement "pending stream" queue to defer full stream initialization until confirmed valid
- [ ] Consider implementing global rate limiters across all connections (not just per-connection)

### Header Compression Bomb Protection
- [ ] Add timeout for receiving complete header block with CONTINUATION frames
- [ ] Implement more sophisticated HPACK bomb detection beyond just size limits

### Additional Security Hardening
- [ ] Add overflow protection for INITIAL_WINDOW_SIZE changes in settings
- [ ] Validate all incoming settings values (e.g., MAX_FRAME_SIZE must be between 2^14 and 2^24-1)
- [ ] Implement connection-level resource tracking and limits

## ⚡ Performance Optimizations

### Concurrency Improvements
- [ ] Implement bounded worker pool for stream handling with configurable size
- [ ] Provide back-pressure mechanism to prevent unbounded fiber creation
- [ ] Consider fiber pool reuse for frequently created/destroyed fibers

### Write Performance
- [ ] Implement dedicated write fiber pattern per connection using channels
- [ ] Eliminate write mutex contention by serializing writes through a single fiber
- [ ] Consider write coalescing for small frames

### Memory Efficiency
- [ ] Use connection-level read buffer with slices for zero-copy frame parsing
- [ ] Implement buffer pooling for frame serialization
- [ ] Reduce allocations in hot paths (frame parsing, HPACK operations)

### HPACK Performance
- [ ] Profile HPACK encoder/decoder under load
- [ ] Optimize dynamic table operations (consider hash map for lookups)
- [ ] Optimize Huffman encoding/decoding with table-driven approach

## 🎛️ Configuration & Settings

### Logging and Observability
- [ ] Add structured logging with configurable levels
- [ ] Implement metrics collection (connection count, stream count, frame rates)
- [ ] Add debug mode with detailed frame logging

### Settings Validation
- [ ] Add comprehensive validation for all HTTP/2 settings parameters
- [ ] Implement settings change notifications to allow application-level handling
- [ ] Add configuration validation on server startup

## 🧪 Testing & Documentation

### Test Coverage
- [ ] Add stress tests for high concurrent connection/stream scenarios
- [ ] Implement fuzzing tests for frame parsing and HPACK decoding
- [ ] Add performance benchmarks with comparison to other HTTP/2 servers

### Documentation
- [ ] Create comprehensive API documentation
- [ ] Add deployment guide with best practices
- [ ] Document performance tuning options
- [ ] Add troubleshooting guide for common issues

## 🚀 Lucky Framework Integration

### Phase 1: Basic Integration
- [ ] Add `ht2` shard to Lucky's `shard.yml`
- [ ] Implement `Lucky::Server::AdapterInterface`
- [ ] Create `Lucky::Server::HTTP2Adapter` wrapping `ht2::Server`
- [ ] Modify `Lucky::ServerRunner` to support HTTP/2 mode

### Phase 2: Request/Response Adaptation
- [ ] Implement mapping from `HT2::Request` to `Lucky::Request`
- [ ] Implement mapping from `Lucky::Response` to `HT2::Response`
- [ ] Handle HTTP/2 pseudo-headers correctly
- [ ] Ensure proper header name case handling

### Phase 3: Middleware Compatibility
- [ ] Update all Lucky middleware for HTTP/2 compatibility
- [ ] Implement server push API if desired
- [ ] Ensure session and CSRF handlers work correctly

### Phase 4: Production Readiness
- [ ] Add HTTP/2-specific configuration options to Lucky
- [ ] Update Lucky documentation for HTTP/2 usage
- [ ] Create migration guide for existing Lucky apps
- [ ] Add HTTP/2-specific tests to Lucky test suite

## 📝 Notes

- Performance optimizations are marked as "Future Work" and can be deferred
- Security enhancements should be prioritized
- RFC compliance issues should be addressed before Lucky integration
- All changes should maintain backward compatibility where possible