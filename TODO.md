# TODO.md

This document tracks remaining tasks for the HT2 HTTP/2 server implementation.

## 📚 Documentation

### API Documentation
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