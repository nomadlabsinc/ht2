require "./spec_helper"
require "./protocol_compliance_spec_helper"

include ProtocolComplianceSpec



describe "RFC9113 Compliance - Header Field Validation" do
  it "raises PROTOCOL_ERROR if :authority and Host headers are inconsistent" do
    with_test_connection do |conn|
      conn.start_server
      conn.ready.receive

      headers = [
        {":method", "GET"},
        {":scheme", "http"},
        {":authority", "localhost"},
        {":path", "/"},
        {"host", "inconsistent-host"}, # Inconsistent Host header
      ]
      headers_frame = HT2::HeadersFrame.new(1, conn.connection.hpack_encoder.encode(headers), flags: HT2::FrameFlags::END_STREAM | HT2::FrameFlags::END_HEADERS)

      conn.send_frame(headers_frame)

      # Expect a GOAWAY frame with PROTOCOL_ERROR
      goaway = conn.expect_frame(HT2::FrameType::GOAWAY)
      goaway.should be_a(HT2::GoAwayFrame)
      goaway.as(HT2::GoAwayFrame).error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
      String.new(goaway.as(HT2::GoAwayFrame).debug_data).should contain(":authority and Host headers must be consistent")

      # Verify connection is closed
      conn.connection.closed?.should be_true
    end
  end

  it "does not reject Host header if consistent with :authority" do
    with_test_connection do |conn|
      conn.start_server
      conn.ready.receive

      headers = [
        {":method", "GET"},
        {":scheme", "http"},
        {":authority", "localhost"},
        {":path", "/"},
        {"host", "localhost"}, # Consistent Host header
      ]
      headers_frame = HT2::HeadersFrame.new(1, conn.connection.hpack_encoder.encode(headers), flags: HT2::FrameFlags::END_STREAM | HT2::FrameFlags::END_HEADERS)

      conn.send_frame(headers_frame)

      # Expect a HEADERS frame in response
      response_headers = conn.expect_frame(HT2::FrameType::HEADERS)
      response_headers.should be_a(HT2::HeadersFrame)

      # Expect a DATA frame with the body
      response_data = conn.expect_frame(HT2::FrameType::DATA)
      response_data.should be_a(HT2::DataFrame)

      # Verify no connection error was raised
      conn.connection.closed?.should be_false
      conn.connection.metrics.errors_received.total.should eq(0)
    end
  end
end

describe "RFC9113 Compliance - CONTINUATION Frame Handling" do
  it "raises PROTOCOL_ERROR if MAX_CONTINUATION_FRAMES limit is exceeded" do
    with_test_connection do |conn|
      conn.start_server
      conn.ready.receive

      # Initial HEADERS frame without END_HEADERS
      headers = [
        {":method", "POST"},
        {":scheme", "http"},
        {":authority", "localhost"},
        {":path", "/upload"},
      ]
      # Encode a large header block to ensure it needs continuation
      large_value = "a" * 1000
      (1..10).each { |i| headers << {"x-custom-header-#{i}", large_value} }

      # First part of headers
      hpack_encoded_headers = conn.connection.hpack_encoder.encode(headers)
      first_part_size = HT2::DEFAULT_MAX_FRAME_SIZE - 5 # Max frame size minus priority data size
      first_part_headers = hpack_encoded_headers[0, first_part_size]
      remaining_headers = hpack_encoded_headers[first_part_size..]

      headers_frame = HT2::HeadersFrame.new(1, first_part_headers, flags: HT2::FrameFlags::None)
      conn.send_frame(headers_frame)

      # Send more CONTINUATION frames than allowed
      max_continuation_frames = HT2::Security::MAX_CONTINUATION_FRAMES
      chunk_size = HT2::DEFAULT_MAX_FRAME_SIZE # Max payload for continuation

      (0..max_continuation_frames).each do |i| # Send one more than allowed
        offset = i * chunk_size
        chunk = remaining_headers[offset, chunk_size]
        break if chunk.empty?

        flags = HT2::FrameFlags::None
        # If this is the last chunk, set END_HEADERS
        flags = HT2::FrameFlags::END_HEADERS if offset + chunk.size >= remaining_headers.size && i < max_continuation_frames # Don't set END_HEADERS on the exceeding frame

        continuation_frame = HT2::ContinuationFrame.new(1, chunk, flags)
        conn.send_frame(continuation_frame)
      end

      # Expect a GOAWAY frame with PROTOCOL_ERROR
      goaway = conn.expect_frame(HT2::FrameType::GOAWAY)
      goaway.should be_a(HT2::GoAwayFrame)
      goaway.as(HT2::GoAwayFrame).error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
      String.new(goaway.as(HT2::GoAwayFrame).debug_data).should contain("CONTINUATION frame count exceeds limit")

      # Verify connection is closed
      conn.connection.closed?.should be_true
    end
  end
end
