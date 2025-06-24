# Summary of Pending Tests

## Total: 22 pending tests

### 1. Connection Pooling (13 tests)
These tests are pending because connection pooling functionality is not yet implemented:

**From `spec/ht2/client_connection_pool_spec.cr`:**
- `reuses the same connection for multiple requests`
- `respects max connections per host`
- `removes unhealthy connections`
- `pre-establishes connections` (#warm_up)
- `gracefully closes connections` (#drain_connections)

**From `spec/ht2/client_spec.cr`:**
- `reuses connections for multiple requests to the same host`
- `creates multiple connections up to the limit`
- `respects max connections per host limit`
- `removes unhealthy connections from the pool`
- `removes idle connections after timeout`
- `pre-establishes connections to a host` (#warm_up)
- `respects max connections limit during warm-up` (#warm_up)
- `gracefully closes all connections` (#drain_connections)
- `waits for active streams to complete` (#drain_connections)
- `drains connections for a specific host` (#drain_connections)

### 2. HTTP Client Methods (5 tests)
These tests are pending because high-level HTTP method convenience functions are not yet implemented:

**From `spec/ht2/client_spec.cr`:**
- `sends GET requests`
- `sends POST requests with body`
- `sends PUT requests with body`
- `sends DELETE requests`
- `sends HEAD requests`

### 3. H2C (HTTP/2 Cleartext) Features (3 tests)
These tests are pending because H2C prior knowledge support is not fully implemented:

**From `spec/h2c_prior_knowledge_spec.cr`:**
- `handles h2c prior knowledge connections`
- `falls back to upgrade when prior knowledge fails`
- `caches h2c support per host`

**From `spec/ht2/h2c_integration_spec.cr`:**
- `accepts direct HTTP/2 connection with prior knowledge`

### 4. Server Push (1 test)
This test is pending because server push is not implemented:

**From `spec/integration/curl_http2_integration_spec.cr`:**
- `handles server push (not implemented)`

### 5. External Tool Integration (2 tests)
These tests are pending to verify compatibility with external HTTP/2 clients:

**From `spec/integration/curl_http2_integration_spec.cr`:**
- `handles requests from python httpx library`
- `handles requests from node.js http2 client`

### 6. Error Handling (1 test)
This test is pending for HTTP/2 fallback support:

**From `spec/ht2/client_spec.cr`:**
- `handles servers that don't support HTTP/2`

## Summary by Feature Priority
1. **Connection Pooling** - 13 tests (critical for performance)
2. **HTTP Client Methods** - 5 tests (convenience methods)
3. **H2C Support** - 4 tests (cleartext HTTP/2)
4. **External Tool Integration** - 2 tests (compatibility verification)
5. **Server Push** - 1 test (advanced feature)
6. **Error Handling** - 1 test (fallback support)