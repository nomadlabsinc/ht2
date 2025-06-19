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

### Direct HTTP/2 Prior Knowledge Support (RFC 7540 Section 3.4)
- [ ] Implement connection type detection without consuming data
  - [ ] Create BufferedSocket wrapper that allows peeking at initial bytes
  - [ ] Implement peek(n) method that doesn't consume bytes from socket
  - [ ] Handle both IO::Buffered and raw socket types
  - [ ] Ensure thread-safe operation for concurrent connections
- [ ] Detect HTTP/2 connection preface (PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n)
  - [ ] Check first 24 bytes for exact match
  - [ ] Distinguish from HTTP/1.1 methods (GET, POST, etc.)
  - [ ] Handle partial reads gracefully
- [ ] Create routing logic in Server#handle_h2c_client
  - [ ] Peek at first bytes to detect connection type
  - [ ] Route to handle_h2c_prior_knowledge for HTTP/2 preface
  - [ ] Route to handle_h2c_upgrade for HTTP/1.1 requests
  - [ ] Handle edge cases (empty reads, timeouts, errors)
- [ ] Implement handle_h2c_prior_knowledge method
  - [ ] Skip HTTP/1.1 upgrade negotiation entirely
  - [ ] Create Connection with buffered socket containing preface
  - [ ] Let Connection.start() consume the preface normally
  - [ ] Apply default settings for the connection
- [ ] Update Connection to work with buffered input
  - [ ] Ensure read operations work with BufferedSocket
  - [ ] Handle transition from buffered to direct socket reads
  - [ ] Maintain performance for non-buffered connections
- [ ] Add prior knowledge client support
  - [ ] Add use_prior_knowledge option to Client
  - [ ] Skip upgrade negotiation when enabled
  - [ ] Send preface immediately after connecting
  - [ ] Cache prior knowledge support per host
- [ ] Create comprehensive tests
  - [ ] Test BufferedSocket peek functionality
  - [ ] Test connection type detection logic
  - [ ] Test prior knowledge server handling
  - [ ] Test prior knowledge client connections
  - [ ] Test mixed connection types (upgrade and prior knowledge)
  - [ ] Performance tests to ensure no regression
- [ ] Update examples and documentation
  - [ ] Add prior knowledge example server
  - [ ] Add prior knowledge example client
  - [ ] Document when to use prior knowledge vs upgrade
  - [ ] Add curl examples with --http2-prior-knowledge


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