# TODO.md

This document tracks remaining tasks for the HT2 HTTP/2 server implementation.

## 🔧 RFC Compliance Issues

### Stream State Management
- [x] Consider refactoring to a more formal state machine pattern


## 🛡️ Security Issues

### Rapid Reset Attack (CVE-2023-44487)
- [x] Implement pending stream queue with configurable limits
- [x] Add per-IP rate limiting for stream creation
- [x] Track and limit rapid stream creation/cancellation patterns
- [x] Add metrics for monitoring rapid reset patterns

## ⚙️ Configuration

### HTTP/2 Clear Text (h2c) Support for Proxy Deployments
- [ ] Implement HTTP/2 prior knowledge (h2c) support for TLS-terminating proxies
  - [ ] Add h2c connection detection in Server#handle_client
  - [ ] Implement HTTP/1.1 Upgrade mechanism (RFC 7540 Section 3.2)
    - [ ] Parse HTTP/1.1 Upgrade request headers
    - [ ] Validate required headers: `Upgrade: h2c`, `HTTP2-Settings`
    - [ ] Decode base64url-encoded SETTINGS payload from HTTP2-Settings header
    - [ ] Send HTTP/1.1 101 Switching Protocols response
    - [ ] Include required response headers: `Connection: Upgrade`, `Upgrade: h2c`
  - [ ] Support direct HTTP/2 prior knowledge (RFC 7540 Section 3.4)
    - [ ] Detect HTTP/2 connection preface without TLS
    - [ ] Skip HTTP/1.1 upgrade for prior knowledge connections
  - [ ] Add Server configuration option for h2c mode
    - [ ] Add `enable_h2c : Bool` parameter to Server constructor
    - [ ] Add `h2c_upgrade_timeout : Time::Span` for upgrade timeout
  - [ ] Update connection initialization for h2c
    - [ ] Skip ALPN validation for h2c connections
    - [ ] Apply SETTINGS from HTTP2-Settings header if present
  - [ ] Add h2c-specific error handling
    - [ ] Handle malformed upgrade requests
    - [ ] Implement upgrade timeout handling
    - [ ] Add appropriate error responses (400, 505)
  - [ ] Create h2c integration tests
    - [ ] Test HTTP/1.1 Upgrade flow
    - [ ] Test direct prior knowledge connections
    - [ ] Test with common reverse proxies (NGINX, HAProxy)
    - [ ] Test error cases and timeouts
  - [ ] Add h2c examples and documentation
    - [ ] Example: Basic h2c server configuration
    - [ ] Example: NGINX reverse proxy with h2c backend
    - [ ] Example: HAProxy configuration for h2c
    - [ ] Document security considerations for h2c
  - [ ] Update client to support h2c
    - [ ] Add h2c upgrade support in Client
    - [ ] Auto-detect h2c capability
    - [ ] Cache h2c support per host

## 🚀 Performance Optimizations

### Connection Management
- [x] Implement connection pooling for client connections
- [x] Add connection warm-up (pre-established connections)
- [x] Implement graceful connection draining

### Stream Processing
- [x] Implement bounded worker pool for stream handling
- [x] Add backpressure mechanisms for slow consumers
- [x] Optimize memory allocation for frame processing

### I/O Optimizations
- [x] Implement zero-copy frame forwarding where possible
- [x] Add vectored I/O for multi-frame writes
- [x] Optimize buffer sizes based on connection patterns

## 🔍 Monitoring & Observability

### Metrics Collection
- [x] Add connection-level metrics (streams, data transferred, errors)
- [x] Add frame-type specific counters
- [x] Implement performance metrics (latency, throughput)
- [x] Add security event metrics

### Debugging Support
- [x] Add debug mode with frame logging
- [x] Implement connection state dumping
- [x] Add stream lifecycle tracing

## 📚 Documentation

### API Documentation
- [x] Document all public APIs with examples
- [ ] Add integration guide for web frameworks
- [ ] Create migration guide from Crystal's HTTP::Server

### Examples
- [ ] Add example: File server with server push
- [ ] Add example: Streaming response server
- [ ] Add example: WebSocket over HTTP/2
- [ ] Add example: gRPC server implementation

## 🧪 Testing

### Integration Tests
- [ ] Add tests for large file transfers
- [ ] Add tests for high concurrency scenarios
- [ ] Add tests for slow client handling
- [ ] Add tests for partial frame scenarios

### Compliance Tests
- [ ] Run against h2spec compliance suite
- [ ] Add tests for each RFC requirement
- [ ] Add negative tests for protocol violations

## 🔄 Framework Integration

### Lucky Framework
- [ ] Create Lucky HTTP/2 adapter
- [ ] Add server push API for Lucky
- [ ] Update Lucky's static file handler for HTTP/2
- [ ] Add HTTP/2 specific middleware support

### Kemal Framework
- [ ] Create Kemal HTTP/2 adapter
- [ ] Add server push support for Kemal
- [ ] Update Kemal's WebSocket handler for HTTP/2
- [ ] Ensure Kemal middleware compatibility

## 🎯 Future Enhancements

### HTTP/3 Preparation
- [ ] Abstract transport layer for QUIC support
- [ ] Prepare connection migration support
- [ ] Design 0-RTT data handling

### Advanced Features
- [ ] Implement server push with cache digests
- [ ] Add support for extended CONNECT method
- [ ] Implement priority hints (RFC 9218)
- [ ] Add support for early hints (103 status)