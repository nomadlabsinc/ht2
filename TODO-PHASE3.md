# HT2 Server Phase 3 Overhaul: Action Plan

This document outlines a detailed action plan to address critical issues in the `ht2` server, focusing on RFC compliance, security vulnerabilities, configuration robustness, and performance optimization. The plan is based on a deep analysis of the current codebase, research into common HTTP/2 CVEs, and best practices from other high-performance server implementations (e.g., Go's `net/http`, Rust's `hyper`).

---

## 1. RFC Compliance Issues

This section details areas where the server's behavior deviates from or fails to fully implement the requirements of HTTP/2 RFCs (primarily RFC 7540 and RFC 7541).

### 1.1. Stream State Management
- **Issue:** The stream state transitions are not fully robust. For example, receiving a `RST_STREAM` on a closed stream should be ignored, but the current logic might not handle all edge cases gracefully. The state validation methods (`validate_send_headers`, etc.) are a good start but need to be exhaustively reviewed against the state diagram in RFC 7540, Section 5.1.
- **Action:**
    - **1.1.1:** Create a comprehensive test suite that forces transitions from every state with every possible frame type to validate correct behavior (accept, reject, or ignore).
    - **1.1.2:** Refactor `stream.cr` to use a more formal state machine pattern, making invalid transitions impossible by design.
    - **1.1.3:** Ensure that receiving frames on a stream in the `CLOSED` state does not trigger any processing or errors, with the exception of `PRIORITY` frames, which can be processed for a short time after closing.

### 1.2. Flow Control
- **Issue:** The connection-level flow control window update logic is basic. It sends a `WINDOW_UPDATE` when the window drops below a simple threshold. This can be inefficient and lead to head-of-line blocking if not managed carefully.
- **Action:**
    - **1.2.1:** Implement a more adaptive window update strategy. Instead of a fixed threshold, the update amount should be based on the rate of data consumption, aiming to keep the pipe full without advertising an excessively large window.
    - **1.2.2:** In `connection.cr`, the check `if @window_size < threshold` is a good start, but the increment calculation `increment = @local_settings[SettingsParameter::INITIAL_WINDOW_SIZE] - @window_size` could be more dynamic. Consider tracking data consumption over time to make a better-informed decision.

### 1.3. Header Validation
- **Issue:** Header name validation in `security.cr` is incorrect. It allows characters forbidden by the RFC and disallows valid ones (e.g., uppercase letters). The RFC specifies that header field names must be valid `token`s, but they are also case-insensitive and should be converted to lowercase.
- **Action:**
    - **1.3.1:** Correct the `validate_header_name` method in `security.cr` to strictly adhere to the `token` definition from RFC 7230, and ensure all header names are converted to lowercase upon processing, as required by HTTP/2.
    - **1.3.2:** Ensure pseudo-headers (`:method`, `:path`, etc.) are validated correctly: they must appear before regular headers, and only valid pseudo-headers for the context (request vs. response) should be present.

### 1.4. Error Handling
- **Issue:** When a stream error occurs, the connection sends a `RST_STREAM`. When a connection error occurs, it sends a `GOAWAY` frame. However, the server does not always provide the most specific error code required by the RFC.
- **Action:**
    - **1.4.1:** Review all `ConnectionError` and `StreamError` exceptions. Ensure the most specific `ErrorCode` is used in every case. For example, a frame size error should raise `FRAME_SIZE_ERROR`, not a generic `PROTOCOL_ERROR`.
    - **1.4.2:** Implement logic to handle `GOAWAY` frames gracefully. When a `GOAWAY` is received, the client should stop creating new streams but can continue processing in-flight streams up to the `last_stream_id`. The current implementation closes streams above this ID but needs robust testing.

---

## 2. Security (CVE) Issues

This section addresses potential vulnerabilities based on known HTTP/2 CVEs and general security best practices.

### 2.1. Denial of Service (DoS) via Resource Exhaustion
- **Issue (CVE-2023-44487 - Rapid Reset):** The server is vulnerable to Rapid Reset attacks. A client can open a stream and immediately send `RST_STREAM`. The current `rst_rate_limiter` and `MAX_TOTAL_STREAMS` are reactive measures. A more proactive defense is needed to prevent resource allocation in the first place.
- **Action:**
    - **2.1.1:** Modify the stream creation logic in `get_or_create_stream` to check limits *before* allocating the `Stream` object and adding it to the `@streams` hash.
    - **2.1.2:** Implement a "pending stream" queue. When a `HEADERS` frame arrives, the stream is only fully initialized after ensuring it's not immediately reset. This adds complexity but is a strong defense.
    - **2.1.3:** The rate limiters in `security.cr` are per-connection. Consider implementing global rate limiters to prevent a single IP from exhausting server resources by opening many connections.

- **Issue (CVE-2019-9515 - SETTINGS Flood):** The `settings_rate_limiter` helps, but the server does not time out waiting for a `SETTINGS` ACK. A malicious client can open a connection, send its `SETTINGS` frame, and never acknowledge the server's `SETTINGS` frame, keeping the connection in a limbo state.
- **Action:**
    - **2.1.4:** In `connection.cr`, when waiting on `@settings_ack_channel`, add a timeout (e.g., 5-10 seconds). If the ACK is not received in time, terminate the connection with a `SETTINGS_TIMEOUT` error code.

- **Issue (CVE-2024-27983 - Continuation Flood):** The server has a `MAX_CONTINUATION_SIZE` check, which is good. However, a client could send an endless stream of `CONTINUATION` frames that are individually small but collectively exhaust memory if the `END_HEADERS` flag is never sent.
- **Action:**
    - **2.1.5:** In addition to the total size check, add a limit on the *number* of `CONTINUATION` frames allowed per `HEADERS` sequence. A reasonable limit would be 10-20 frames.
    - **2.1.6:** Implement a timeout for receiving the complete header block. If the `END_HEADERS` flag isn't received within a short period after the initial `HEADERS` frame, drop the connection.

- **Issue (HPACK Bomb / Header List Size):** The server sends `MAX_HEADER_LIST_SIZE` in its `SETTINGS`, but it's not clear if it enforces this limit on incoming headers. The `hpack_decoder.decode` call could potentially return a list of headers that exceeds this limit, leading to excessive memory use.
- **Action:**
    - **2.1.7:** Modify the HPACK decoder to accept a `max_size` parameter. During decompression, it should track the total size of the emitted header list and raise a `COMPRESSION_ERROR` if the limit is exceeded. This is a critical security fix.

---

## 3. Configuration & Settings Issues

This section covers improvements to server configuration and the handling of HTTP/2 settings.

### 3.1. Default Settings
- **Issue:** The default values for settings like `MAX_CONCURRENT_STREAMS` are hardcoded. While reasonable, they may not be optimal for all use cases.
- **Action:**
    - **3.1.1:** Expose all key HTTP/2 settings (`MAX_CONCURRENT_STREAMS`, `INITIAL_WINDOW_SIZE`, `MAX_FRAME_SIZE`, `MAX_HEADER_LIST_SIZE`) in the `Server` constructor with sensible defaults. This is already partially done but should be comprehensive.
    - **3.1.2:** Add logging to display the effective settings when the server starts and when a new connection is configured.

### 3.2. Settings Application
- **Issue:** The server applies settings received from the client immediately. Some settings, like `INITIAL_WINDOW_SIZE`, have complex effects on all existing streams.
- **Action:**
    - **3.2.1:** The current implementation for `INITIAL_WINDOW_SIZE` change is correct in applying the delta to all streams. However, this logic needs to be protected against integer overflows if a malicious client sends extreme values, even though the value is a `UInt32`. The `checked_add` in `stream.cr` is good, but the initial diff calculation in `connection.cr` should also be handled with care.
    - **3.2.2:** Add validation for incoming settings values. For example, `MAX_FRAME_SIZE` must be between 2^14 and 2^24-1. The server should reject invalid values with a `PROTOCOL_ERROR`.

---

## 4. Performance Issues

This section identifies opportunities for performance optimization, drawing on Crystal best practices and patterns from other languages.

### 4.1. Concurrency Model
- **Issue:** The server uses `spawn` for each new client and `spawn` for each new stream. While idiomatic for Crystal, this unbounded creation of fibers can lead to scheduler pressure and resource exhaustion under very high load.
- **Action:**
    - **4.1.1:** Implement a bounded worker pool for request handling (`handle_stream`). Instead of `spawn`, push the stream-handling task onto a channel that is serviced by a fixed number of worker fibers. This provides back-pressure and makes the server more resilient to load spikes.
    - **4.1.2:** The `spawn handle_client` is generally fine, as the number of concurrent connections is a more manageable metric.

### 4.2. Write Contention
- **Issue:** `Connection#send_frame` uses a `@write_mutex` to serialize all frame writes to the socket. This is necessary but can become a bottleneck if multiple fibers (for different streams) are trying to send data simultaneously.
- **Action:**
    - **4.2.1:** Implement a dedicated "write fiber" for each connection. Instead of multiple fibers acquiring a mutex to write to the socket, they would push their frames onto a channel. The single write fiber would read from this channel and write to the socket, eliminating mutex contention. This pattern is common in Go and Rust HTTP/2 implementations.

### 4.3. Memory Allocations
- **Issue:** The `read_loop` allocates a new `Bytes` object for the header and payload on every single frame. This can create significant GC pressure.
- **Action:**
    - **4.3.1:** Use a connection-level read buffer. Read data from the socket into a larger, reusable buffer. Then, parse frames by taking slices (`Bytes.to_slice`) of this buffer instead of allocating new `Bytes` objects for each frame. This zero-copy approach is a hallmark of high-performance servers.
    - **4.3.2:** Review `frame.cr`'s `to_bytes` method. It allocates a new `Bytes` object for every serialized frame. For small frames, this is acceptable, but a buffer pooling strategy could be beneficial.

### 4.4. HPACK Optimization
- **Issue:** The HPACK implementation details are not provided, but this is a performance-critical component. Inefficient string operations or table lookups can slow down header processing.
- **Action:**
    - **4.4.1:** Profile the HPACK encoder and decoder under load.
    - **4.4.2:** Ensure the dynamic table implementation is efficient (e.g., using a hash map for lookups and a circular buffer for eviction).
    - **4.4.3:** Optimize the Huffman encoding/decoding logic. Table-driven decoding is typically much faster than bit-by-bit processing.
