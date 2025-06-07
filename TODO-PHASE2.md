# Lucky Framework Changes

This section assumes `ht2` shard is complete and available. It details changes required within the Lucky framework itself.

## 1. Core Framework Modifications

### 1.1. Configuration
- [ ] Add new configuration options in `config/server.cr` (or equivalent) for HTTP/2:
    - [ ] `config.http2.enabled = true/false` (default to `false` initially).
    - [ ] `config.http2.port` (if different from HTTP/1.1, though typically same port with ALPN).
    - [ ] `config.http2.tls_key_file` and `config.http2.tls_cert_file` (emphasize TLS requirement).
    - [ ] Expose relevant `ht2::Server` settings (e.g., `max_concurrent_streams`, `initial_window_size`).
- [ ] Update `lucky watch` and server startup commands (`Lucky::ServerRunner` or similar) to read and apply these configurations.
- [ ] Ensure development mode (auto-reload) is compatible with the new server setup.

### 1.2. Server Abstraction Layer (Recommended)
- [ ] Define a `Lucky::Server::AdapterInterface` (e.g., using an abstract class or module).
    - [ ] Common methods: `initialize(config)`, `listen`, `close`.
    - [ ] Common handler signature or adaptation logic.
- [ ] Create `Lucky::Server::HTTP1Adapter` wrapping `Crystal::HTTP::Server` and conforming to `AdapterInterface`.
    - [ ] This adapter would use existing Lucky HTTP/1.1 logic.
- [ ] Create `Lucky::Server::HTTP2Adapter` wrapping `ht2::Server` and conforming to `AdapterInterface`.
    - [ ] This adapter will integrate the new `ht2` shard.
- [ ] Refactor `Lucky::ServerRunner` (or equivalent) to instantiate and use the appropriate adapter based on configuration (`config.http2.enabled`).

### 1.3. Request/Response Object Adaptation
- [ ] Review `Lucky::Request` and `Lucky::Response`.
- [ ] If `ht2` uses its own request/response objects (`HT2::Request`, `HT2::Response`):
    - [ ] Implement mapping logic from `HT2::Request` to `Lucky::Request`.
        - [ ] Ensure correct population of `method`, `path`, `headers`, `body`, `params`, `cookies`, `remote_ip`, `scheme`, `host`, `port`.
        - [ ] Pay special attention to HTTP/2 pseudo-headers and lowercase header names.
    - [ ] Implement mapping logic from `Lucky::Response` to `HT2::Response`.
        - [ ] Ensure correct setting of `status_code`, `headers`, `body`.
- [ ] If `ht2` can work directly with `HTTP::Request` and `HTTP::Response` (or compatible types), ensure full compatibility.
- [ ] Update `Lucky::Route` and dispatching mechanism to handle requests from the HTTP/2 server.

### 1.4. Middleware and Handler Compatibility
- [ ] Review all built-in Lucky middleware/handlers:
    - [ ] `Lucky::StaticFileHandler`: Consider opportunities for server push (e.g., pushing linked CSS/JS for an HTML file).
    - [ ] `Lucky::ForceSSLHandler`: Behavior might need adjustment as HTTP/2 is typically run over TLS. Could be a no-op or verify scheme.
    - [ ] `Lucky::ErrorHandler`: Ensure error responses are correctly formatted for HTTP/2.
    - [ ] `Lucky::Session::SaveSessionHandler`: Ensure cookie handling is compatible.
    - [ ] `Lucky::CSRFHandler`: Verify token mechanisms.
- [ ] Ensure all custom headers set by Lucky or application code are handled correctly (e.g. case-insensitivity for lookup, lowercase for sending).
- [ ] Update any middleware that directly interacts with `HTTP::Server::Context` to use the new `HT2::Context` or an abstracted version.

### 1.5. TLS Management
- [ ] Ensure Lucky's TLS configuration (`config.ssl_key_file`, `config.ssl_cert_file`) can be used by `ht2::Server`.
- [ ] Verify ALPN is correctly configured when TLS is enabled for HTTP/2.
- [ ] Update documentation regarding TLS setup, emphasizing its necessity for browser-based HTTP/2.

### 1.6. Testing
- [ ] Update existing integration and acceptance tests to run over an HTTP/2-enabled server.
- [ ] Add new tests specifically for HTTP/2 functionality if Lucky exposes any (e.g., server push APIs).
- [ ] Test behavior with mixed HTTP/1.1 and HTTP/2 configurations if supported.
- [ ] Perform thorough testing with various HTTP/2 clients (browsers, curl with HTTP/2).

### 1.7. Documentation Updates
- [ ] Update Lucky guides on server configuration to include HTTP/2 settings.
- [ ] Document any changes in behavior or new features related to HTTP/2.
- [ ] Provide guidance for application developers on how to leverage HTTP/2 (e.g., implications for asset loading, server push if available).
- [ ] Update deployment guides with considerations for HTTP/2 (e.g., reverse proxy configuration like Nginx/HAProxy for HTTP/2 termination or pass-through).

## 2. Integrating `ht2` Shard - Multi-Step Action Plan

This assumes the Server Abstraction Layer (1.2) is being implemented.

### 2.1. Phase 1: Initial Setup and Basic Integration
- [ ] Add `ht2` shard to Lucky's `shard.yml`.
- [ ] Implement the `Lucky::Server::AdapterInterface`.
- [ ] Implement `Lucky::Server::HTTP1Adapter` by refactoring existing `HTTP::Server` usage into it. Ensure Lucky works as before with this adapter.
- [ ] Implement the basic structure of `Lucky::Server::HTTP2Adapter`, instantiating `ht2::Server`.
- [ ] Modify `Lucky::ServerRunner` to select and use `HTTP1Adapter` or `HTTP2Adapter` based on `config.http2.enabled`.

### 2.2. Phase 2: Request/Response Path Adaptation
- [ ] Implement the handler logic within `Lucky::Server::HTTP2Adapter` to:
    - [ ] Receive `HT2::Context` (or equivalent) from `ht2::Server`.
    - [ ] Convert/map `HT2::Request` to `Lucky::Request`.
    - [ ] Pass `Lucky::Request` through Lucky's routing and action dispatch.
    - [ ] Receive `Lucky::Response` from the action.
    - [ ] Convert/map `Lucky::Response` back to `HT2::Response` and send it.
- [ ] Thoroughly test this request/response flow with simple routes and actions.

### 2.3. Phase 3: Middleware and Advanced Feature Compatibility
- [ ] Systematically review and update each piece of Lucky middleware (as per 1.4) for compatibility with the `HTTP2Adapter` flow.
- [ ] Test file serving, error handling, sessions, CSRF, etc., over HTTP/2.
- [ ] If `ht2` supports server push and Lucky wants to expose it:
    - [ ] Design an API in `Lucky::Response` (e.g., `response.push("/assets/style.css")`).
    - [ ] Implement this API to call the underlying `ht2::Response#push_promise` method.

### 2.4. Phase 4: Configuration, TLS, and Edge Cases
- [ ] Fully implement configuration loading for all `config.http2.*` settings in `Lucky::Server::HTTP2Adapter`.
- [ ] Ensure TLS context setup and ALPN negotiation are robust.
- [ ] Test various edge cases: large uploads/downloads, many concurrent requests, slow clients, error conditions (stream resets, connection drops).

### 2.5. Phase 5: Testing, Documentation, and Release Preparation
- [ ] Conduct comprehensive end-to-end testing of Lucky applications running with `config.http2.enabled = true`.
- [ ] Perform performance benchmarks comparing HTTP/1.1 (via `HTTP1Adapter`) and HTTP/2 (via `HTTP2Adapter`).
- [ ] Write all necessary documentation updates for Lucky users (guides, API docs).
- [ ] Prepare release notes detailing the new HTTP/2 support.
- [ ] Consider a beta release or feature flag period for wider testing.

This checklist provides a detailed roadmap. Each item may represent significant effort and further sub-tasks.
