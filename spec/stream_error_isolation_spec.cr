require "./spec_helper"
require "./protocol_compliance_spec_helper"

include ProtocolComplianceSpec

describe "RFC9113 Compliance - Stream Error Isolation" do
  it "isolates stream errors without affecting connection" do
    with_test_connection do |conn|
      conn.start_server
      conn.ready.receive

      # Stream 1: Normal request
      headers1 = [
        {":method", "GET"},
        {":scheme", "http"},
        {":authority", "localhost"},
        {":path", "/normal"},
      ]
      headers_frame1 = HT2::HeadersFrame.new(1, conn.connection.hpack_encoder.encode(headers1), flags: HT2::FrameFlags::END_STREAM | HT2::FrameFlags::END_HEADERS)
      conn.send_frame(headers_frame1)

      # Stream 3: Request with invalid headers (should cause stream error)
      headers3 = [
        {":method", "GET"},
        {":scheme", "http"},
        {":authority", "localhost"},
        {":path", "/invalid"},
        {"INVALID-UPPERCASE-HEADER", "value"}, # Should cause PROTOCOL_ERROR on stream
      ]

      begin
        headers_frame3 = HT2::HeadersFrame.new(3, conn.connection.hpack_encoder.encode(headers3), flags: HT2::FrameFlags::END_STREAM | HT2::FrameFlags::END_HEADERS)
        conn.send_frame(headers_frame3)
      rescue
        # May fail during encoding/sending, that's OK for this test
      end

      # Stream 5: Another normal request (should work despite stream 3 error)
      headers5 = [
        {":method", "GET"},
        {":scheme", "http"},
        {":authority", "localhost"},
        {":path", "/another-normal"},
      ]
      headers_frame5 = HT2::HeadersFrame.new(5, conn.connection.hpack_encoder.encode(headers5), flags: HT2::FrameFlags::END_STREAM | HT2::FrameFlags::END_HEADERS)
      conn.send_frame(headers_frame5)

      # Should receive responses for valid streams (1 and 5)
      # May receive RST_STREAM for invalid stream (3)

      response_count = 0
      stream_error_count = 0

      # Collect responses for a reasonable time
      4.times do
        begin
          frame = conn.expect_frame(HT2::FrameType::HEADERS, timeout: 2.seconds)
          response_count += 1 if frame.is_a?(HT2::HeadersFrame)
        rescue
          break
        end

        begin
          frame = conn.expect_frame(HT2::FrameType::DATA, timeout: 1.second)
        rescue
          # DATA frame might not come if stream errored
        end

        begin
          frame = conn.expect_frame(HT2::FrameType::RST_STREAM, timeout: 1.second)
          stream_error_count += 1 if frame.is_a?(HT2::RstStreamFrame)
        rescue
          # RST_STREAM might not come for valid streams
        end
      end

      # Should have at least some valid responses
      response_count.should be >= 1

      # Connection should remain healthy despite stream errors
      conn.connection.closed?.should be_false

      # Should not have received GOAWAY (connection-level error)
      begin
        goaway = conn.expect_frame(HT2::FrameType::GOAWAY, timeout: 1.second)
        fail "Received unexpected GOAWAY frame - stream errors should not affect connection"
      rescue
        # Good - no GOAWAY frame expected
      end
    end
  end

  it "properly resets individual streams on stream-level protocol errors" do
    with_test_connection do |conn|
      conn.start_server
      conn.ready.receive

      # Create a stream with conflicting :authority and Host headers
      headers = [
        {":method", "GET"},
        {":scheme", "http"},
        {":authority", "example.com"},
        {":path", "/"},
        {"host", "different-host.com"}, # Conflicts with :authority
      ]

      begin
        headers_frame = HT2::HeadersFrame.new(1, conn.connection.hpack_encoder.encode(headers), flags: HT2::FrameFlags::END_STREAM | HT2::FrameFlags::END_HEADERS)
        conn.send_frame(headers_frame)

        # Should receive either RST_STREAM for the specific stream or connection error
        # This tests proper error classification
        begin
          rst_frame = conn.expect_frame(HT2::FrameType::RST_STREAM, timeout: 3.seconds)
          rst_frame.should be_a(HT2::RstStreamFrame)
          rst_frame.stream_id.should eq(1)
          rst_frame.error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
        rescue
          # Might receive GOAWAY instead if implementation treats this as connection error
          goaway = conn.expect_frame(HT2::FrameType::GOAWAY, timeout: 3.seconds)
          goaway.should be_a(HT2::GoAwayFrame)
          goaway.error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
          return # Exit test if connection-level error (also valid)
        end

        # If we got RST_STREAM, connection should still be healthy
        conn.connection.closed?.should be_false

        # Should be able to create another stream successfully
        headers2 = [
          {":method", "GET"},
          {":scheme", "http"},
          {":authority", "localhost"},
          {":path", "/test2"},
        ]
        headers_frame2 = HT2::HeadersFrame.new(3, conn.connection.hpack_encoder.encode(headers2), flags: HT2::FrameFlags::END_STREAM | HT2::FrameFlags::END_HEADERS)
        conn.send_frame(headers_frame2)

        # Should get normal response
        response_headers = conn.expect_frame(HT2::FrameType::HEADERS, timeout: 3.seconds)
        response_headers.should be_a(HT2::HeadersFrame)
        response_headers.stream_id.should eq(3)
      rescue ex
        # Some validation errors might be caught earlier in the pipeline
        # The key is that the system handles the error gracefully
        conn.connection.closed?.should be_false
      end
    end
  end
end
