# HT2 Server Phase 3 Overhaul: Action Plan

This document outlines remaining tasks for the `ht2` server. Many security features and core functionality have already been implemented.

---

## 1. RFC Compliance Issues (Remaining)

### 1.1. Stream State Management Enhancements
- **Issue:** While basic state management is implemented, edge cases need better handling (e.g., PRIORITY frames on recently closed streams).
- **Action:**
    - **1.1.1:** Create comprehensive test suite for all state transitions with every frame type
    - **1.1.2:** Consider refactoring to a more formal state machine pattern
    - **1.1.3:** Ensure PRIORITY frames can be processed for a short time after stream closure

### 1.2. Adaptive Flow Control
- **Issue:** Current window update strategy uses a simple threshold. Can be optimized for better performance.
- **Action:**
    - **1.2.1:** Implement adaptive window update strategy based on data consumption rate
    - **1.2.2:** Make increment calculation more dynamic instead of fixed threshold

### 1.3. Header Validation Fixes
- **Issue:** Header name validation needs to match RFC token definition exactly and ensure lowercase conversion.
- **Action:**
    - **1.3.1:** Fix `validate_header_name` to match RFC 7230 token definition
    - **1.3.2:** Ensure all header names are converted to lowercase

### 1.4. Error Code Specificity
- **Issue:** Not all errors use the most specific error code required by RFC.
- **Action:**
    - **1.4.1:** Review all error cases and use most specific ErrorCode
    - **1.4.2:** Add more comprehensive GOAWAY handling tests

---

## 2. Security Enhancements (Remaining)

### 2.1. Rapid Reset Defense Enhancement
- **Issue:** Current defenses are reactive. Need proactive measures.
- **Action:**
    - **2.1.1:** Check stream limits *before* allocating Stream objects
    - **2.1.2:** Implement "pending stream" queue to defer full initialization
    - **2.1.3:** Consider global rate limiters across all connections

### 2.2. SETTINGS ACK Timeout
- **Issue:** No timeout for SETTINGS acknowledgment.
- **Action:**
    - **2.2.1:** Add 5-10 second timeout when waiting for SETTINGS ACK

### 2.3. CONTINUATION Frame Count Limit
- **Issue:** Only size limit exists, not frame count limit.
- **Action:**
    - **2.3.1:** Add limit on number of CONTINUATION frames (10-20)
    - **2.3.2:** Add timeout for receiving complete header block

### 2.4. HPACK Decoder Size Enforcement
- **Issue:** MAX_HEADER_LIST_SIZE not enforced during decompression.
- **Action:**
    - **2.4.1:** Modify HPACK decoder to accept and enforce max_size parameter

---

## 3. Configuration & Settings (Remaining)

### 3.1. Comprehensive Settings Exposure
- **Issue:** Not all HTTP/2 settings are configurable via Server constructor.
- **Action:**
    - **3.1.1:** Expose all key settings with sensible defaults
    - **3.1.2:** Add startup logging for effective settings

### 3.2. Settings Validation
- **Issue:** Incoming settings need better validation.
- **Action:**
    - **3.2.1:** Add overflow protection for INITIAL_WINDOW_SIZE changes
    - **3.2.2:** Validate all incoming settings (e.g., MAX_FRAME_SIZE range)

---

## 4. Performance Optimizations (Future Work)

### 4.1. Bounded Worker Pool
- **Issue:** Unbounded fiber creation can cause scheduler pressure.
- **Action:**
    - **4.1.1:** Implement bounded worker pool for stream handling
    - **4.1.2:** Provide back-pressure mechanism

### 4.2. Write Fiber Pattern
- **Issue:** Write mutex can become bottleneck.
- **Action:**
    - **4.2.1:** Implement dedicated write fiber per connection using channels

### 4.3. Zero-Copy Reads
- **Issue:** Frame reading allocates new Bytes for each frame.
- **Action:**
    - **4.3.1:** Use connection-level read buffer with slices
    - **4.3.2:** Consider buffer pooling for frame serialization

### 4.4. HPACK Performance
- **Action:**
    - **4.4.1:** Profile HPACK under load
    - **4.4.2:** Optimize dynamic table operations
    - **4.4.3:** Optimize Huffman encoding/decoding

---

## Already Implemented Features

The following features from the original TODO have been implemented:
- ✅ All rate limiters (settings, rst, ping, priority)
- ✅ Basic security validations and constants
- ✅ Complete HPACK implementation with static/dynamic tables
- ✅ Stream state machine with proper transitions
- ✅ Basic flow control with window management
- ✅ Connection and stream limits (MAX_TOTAL_STREAMS)
- ✅ Error handling with specific error codes
- ✅ SETTINGS frame handling with rate limiting
- ✅ CONTINUATION frame size limits
- ✅ Thread-safe frame sending with mutex
- ✅ Protection against multiple CVEs
- ✅ GOAWAY frame handling