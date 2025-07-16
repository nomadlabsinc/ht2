require "./spec_helper"
require "./protocol_compliance_spec_helper"

include ProtocolComplianceSpec

describe "RFC9113 Compliance - PRIORITY Frame Deprecation" do
  it "ignores PRIORITY frames without affecting stream processing" do
    with_test_connection do |conn|
      conn.start_server
      conn.ready.receive

      # Send a PRIORITY frame (should be ignored)
      priority_payload = Bytes.new(5)
      # E flag = 0, stream dependency = 0, weight = 15
      priority_payload[0] = 0x00_u8 # E flag + stream dependency (bits 31-24)
      priority_payload[1] = 0x00_u8 # stream dependency (bits 23-16)
      priority_payload[2] = 0x00_u8 # stream dependency (bits 15-8)
      priority_payload[3] = 0x00_u8 # stream dependency (bits 7-0)
      priority_payload[4] = 0x0F_u8 # weight (15)

      # Create PRIORITY frame manually using UnknownFrame
      priority_frame = HT2::UnknownFrame.new(
        1_u32,
        HT2::FrameType::PRIORITY,
        HT2::FrameFlags::None,
        priority_payload
      )
      conn.send_frame(priority_frame)

      # Send a normal HEADERS frame after the PRIORITY frame
      headers = [
        {":method", "GET"},
        {":scheme", "http"},
        {":authority", "localhost"},
        {":path", "/"},
      ]
      headers_frame = HT2::HeadersFrame.new(1, conn.connection.hpack_encoder.encode(headers), flags: HT2::FrameFlags::END_STREAM | HT2::FrameFlags::END_HEADERS)
      conn.send_frame(headers_frame)

      # Should receive normal response despite PRIORITY frame
      response_headers = conn.expect_frame(HT2::FrameType::HEADERS)
      response_headers.should be_a(HT2::HeadersFrame)

      response_data = conn.expect_frame(HT2::FrameType::DATA)
      response_data.should be_a(HT2::DataFrame)

      # Verify connection is still healthy
      conn.connection.closed?.should be_false
      conn.connection.metrics.errors_received.total.should eq(0)
    end
  end

  it "ignores priority information in HEADERS frames with PRIORITY flag" do
    with_test_connection do |conn|
      conn.start_server
      conn.ready.receive

      headers = [
        {":method", "GET"},
        {":scheme", "http"},
        {":authority", "localhost"},
        {":path", "/"},
      ]

      # Create HEADERS frame with PRIORITY flag set
      header_block = conn.connection.hpack_encoder.encode(headers)

      # Set PRIORITY flag along with other flags - this will test that priority info is ignored
      flags = HT2::FrameFlags::END_STREAM | HT2::FrameFlags::END_HEADERS | HT2::FrameFlags::PRIORITY

      # The HeadersFrame constructor should handle the PRIORITY flag correctly
      headers_frame = HT2::HeadersFrame.new(1_u32, header_block, flags)
      conn.send_frame(headers_frame)

      # Should receive normal response despite priority information
      response_headers = conn.expect_frame(HT2::FrameType::HEADERS)
      response_headers.should be_a(HT2::HeadersFrame)

      response_data = conn.expect_frame(HT2::FrameType::DATA)
      response_data.should be_a(HT2::DataFrame)

      # Verify connection is still healthy
      conn.connection.closed?.should be_false
      conn.connection.metrics.errors_received.total.should eq(0)
    end
  end

  it "does not process priority dependencies from deprecated priority frames" do
    with_test_connection do |conn|
      conn.start_server
      conn.ready.receive

      # Send PRIORITY frame establishing a dependency (should be ignored)
      priority_payload = Bytes.new(5)
      # Stream 3 depends on stream 1 with weight 100
      priority_payload[0] = 0x00_u8 # E flag + stream dependency (bits 31-24)
      priority_payload[1] = 0x00_u8 # stream dependency (bits 23-16)
      priority_payload[2] = 0x00_u8 # stream dependency (bits 15-8)
      priority_payload[3] = 0x01_u8 # stream dependency = 1 (bits 7-0)
      priority_payload[4] = 0x64_u8 # weight = 100

      # Create PRIORITY frame manually using UnknownFrame
      priority_frame = HT2::UnknownFrame.new(
        3_u32,
        HT2::FrameType::PRIORITY,
        HT2::FrameFlags::None,
        priority_payload
      )
      conn.send_frame(priority_frame)

      # Create streams 1 and 3 with requests
      [1_u32, 3_u32].each do |stream_id|
        headers = [
          {":method", "GET"},
          {":scheme", "http"},
          {":authority", "localhost"},
          {":path", "/stream-#{stream_id}"},
        ]
        headers_frame = HT2::HeadersFrame.new(
          stream_id,
          conn.connection.hpack_encoder.encode(headers),
          flags: HT2::FrameFlags::END_STREAM | HT2::FrameFlags::END_HEADERS
        )
        conn.send_frame(headers_frame)
      end

      # Both streams should be processed normally without priority considerations
      # The order of responses doesn't matter since priority is deprecated
      2.times do
        response_headers = conn.expect_frame(HT2::FrameType::HEADERS)
        response_headers.should be_a(HT2::HeadersFrame)

        response_data = conn.expect_frame(HT2::FrameType::DATA)
        response_data.should be_a(HT2::DataFrame)
      end

      # Verify no connection errors occurred
      conn.connection.closed?.should be_false
      conn.connection.metrics.errors_received.total.should eq(0)
    end
  end
end
