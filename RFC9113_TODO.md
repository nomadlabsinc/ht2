# RFC 9113 Compliance TODO

This document outlines the necessary changes to bring the `ht2` implementation into compliance with RFC 9113.

**Last Updated:** 2025-07-16
**Current Implementation Status:** Mostly Compliant with identified gaps

## 1. Priority Signaling (Section 5.3)

**Status:** ✅ COMPLIANT (Fixed)

**Issue:** RFC 9113 deprecates the priority signaling mechanism defined in RFC 7540. The `PRIORITY` frame and the priority fields in `HEADERS` frames are now considered obsolete.

**Current Implementation:**
- ✅ `Connection#handle_priority_frame` correctly ignores PRIORITY frames (src/ht2/connection.cr:891-894)
- ✅ `HeadersFrame.parse_payload` properly ignores priority information in HEADERS frames (src/ht2/frames/headers_frame.cr:64-74)
- ✅ Test coverage exists in spec/rfc9113_compliance_spec.cr

**Remaining Action:** None - fully compliant

## 2. HTTP/1.1 Upgrade (h2c)

**Status:** ⚠️ COMPLIANT BUT DEPRECATED

**Issue:** The HTTP/1.1 `Upgrade` mechanism for establishing cleartext HTTP/2 (h2c) connections is deprecated in RFC 9113 in favor of prior knowledge or HTTPS with ALPN.

**Current Implementation:**
- ✅ h2c support is configurable and not enabled by default
- ✅ Implementation follows RFC standards

**Action:** Document as deprecated feature. No code changes required.

## 3. Header Field Validation

**Status:** ✅ COMPLIANT (Fixed)

### 3.1. `:authority` vs. `Host` Header

**Current Implementation:**
- ✅ `Request.from_stream` enforces :authority and Host header consistency (src/ht2/request.cr:53-62)
- ✅ Raises PROTOCOL_ERROR when headers are inconsistent
- ✅ Test coverage exists in spec/rfc9113_compliance_spec.cr

### 3.2. Connection-Specific Headers

**Status:** ✅ COMPLIANT

**Current Implementation:**
- ✅ `HeaderValidator` correctly excludes "host" from CONNECTION_SPECIFIC_HEADERS (src/ht2/header_validator.cr:14-17)
- ✅ Host header is allowed and validated for consistency with :authority

## 4. CONTINUATION Frame Handling

**Status:** ✅ COMPLIANT

**Current Implementation:**
- ✅ MAX_CONTINUATION_FRAMES limit properly enforced (src/ht2/security.cr)
- ✅ PROTOCOL_ERROR raised when limit exceeded
- ✅ Test coverage exists in spec/rfc9113_compliance_spec.cr

## 5. Extended CONNECT Protocol

**Status:** ✅ COMPLIANT (Optional Feature)

**Issue:** RFC 9113 introduces the extended CONNECT protocol with `:protocol` pseudo-header.

**Current Implementation:**
- ✅ Not implemented, but this is an optional feature per RFC 9113
- ✅ No compliance violation

## 6. Additional RFC 9113 Compliance Areas Reviewed

### 6.1. Frame Processing and Validation

**Status:** ✅ COMPLIANT

**Current Implementation:**
- ✅ Frame header parsing follows RFC 9113 (src/ht2/frame.cr:67-89)
- ✅ Stream ID validation and reserved bit handling correct
- ✅ Frame size limits enforced

### 6.2. Stream State Management

**Status:** ✅ COMPLIANT

**Current Implementation:**
- ✅ Stream state machine follows RFC 9113 (src/ht2/stream_state_machine.cr)
- ✅ Proper state transitions and error handling
- ✅ Closed stream tracking and validation

### 6.3. HPACK Implementation

**Status:** ✅ COMPLIANT

**Current Implementation:**
- ✅ HPACK decoder follows RFC 7541 (compatible with RFC 9113) (src/ht2/hpack/decoder.cr)
- ✅ Proper header name case handling (lowercasing non-pseudo headers)
- ✅ Dynamic table size management
- ✅ Header list size limits enforced

### 6.4. Flow Control

**Status:** ✅ COMPLIANT

**Current Implementation:**
- ✅ Connection and stream-level flow control properly implemented
- ✅ Window size management follows RFC 9113
- ✅ Adaptive flow control enhancements beyond RFC requirements

### 6.5. Error Handling

**Status:** ✅ COMPLIANT

**Current Implementation:**
- ✅ Proper error codes used according to RFC 9113
- ✅ Connection vs stream errors handled correctly
- ✅ GOAWAY frame generation and handling

## 7. Security and Robustness Enhancements (Beyond RFC 9113)

**Status:** ✅ ENHANCED COMPLIANCE

**Current Implementation:**
- ✅ Rate limiting for various frame types (src/ht2/security.cr)
- ✅ Rapid reset protection (src/ht2/rapid_reset_protection.cr)
- ✅ Buffer management and memory protection
- ✅ Connection metrics and monitoring

## Test Coverage Status

**Existing Test Coverage:**
- ✅ RFC 9113 compliance tests (spec/rfc9113_compliance_spec.cr)
- ✅ Protocol compliance test framework (spec/protocol_compliance_spec_helper.cr)
- ✅ Header validation tests
- ✅ Frame processing tests
- ✅ Stream state tests
- ✅ HPACK tests

**Test Framework:**
- ✅ In-memory test connections for protocol-level testing
- ✅ Docker-based integration tests
- ✅ h2spec compliance testing
- ✅ Red-Green-Refactor patterns in place

## Summary

**Overall RFC 9113 Compliance Status: ✅ FULLY COMPLIANT**

The ht2 implementation demonstrates full compliance with RFC 9113 requirements:

1. **Priority signaling deprecation** - Properly handled
2. **Header field validation** - Correctly implemented with :authority/Host consistency
3. **Frame processing** - Follows all RFC 9113 specifications
4. **Error handling** - Appropriate error codes and connection management
5. **Security** - Enhanced beyond RFC requirements with additional protections

**Recommendations:**
1. Continue running comprehensive test suite in Docker
2. Maintain h2spec compliance testing
3. Document h2c support as deprecated but available
4. Consider implementing extended CONNECT protocol as future enhancement

**No immediate code changes required for RFC 9113 compliance.**
