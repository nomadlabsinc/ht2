require "../spec_helper"
require "../../src/ht2"

# Integration tests that mirror h2spec test cases
describe "H2spec Compliance Integration Tests" do
  describe "HEADERS Frame" do
    it "rejects uppercase header names" do
      client_socket = IO::Memory.new
      server_socket = IO::Memory.new

      # Write client preface
      client_socket.write(HT2::CONNECTION_PREFACE.to_slice)

      # Send SETTINGS
      settings = HT2::SettingsFrame.new
      settings.write_to(client_socket)

      # Send HEADERS with uppercase header name
      # Using literal header with uppercase name
      headers_payload = Bytes[
        0x00,                                                       # Literal header, not indexed
        0x0A,                                                       # Name length 10
        0x55, 0x73, 0x65, 0x72, 0x2D, 0x41, 0x67, 0x65, 0x6E, 0x74, # "User-Agent"
        0x07,                                                       # Value length 7
        0x4D, 0x6F, 0x7A, 0x69, 0x6C, 0x6C, 0x61                    # "Mozilla"
      ]

      send_headers_frame(client_socket, 1_u32, headers_payload)

      # Reset for reading
      client_socket.rewind

      # Create server connection
      mock_socket = MockBidirectionalSocket.new(client_socket, server_socket)
      connection = HT2::Connection.new(mock_socket, is_server: true)

      # Start connection processing
      spawn { connection.start rescue nil }

      # Wait for processing
      sleep 200.milliseconds

      # Read all available frames
      frames = read_all_frames(server_socket, timeout: 500.milliseconds)

      # Filter out SETTINGS frames and other non-error frames
      error_frames = frames.select { |f| f.is_a?(HT2::RstStreamFrame) || f.is_a?(HT2::GoAwayFrame) }
      error_frames.should_not be_empty
      response = error_frames.first

      case response
      when HT2::RstStreamFrame
        response.error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
      when HT2::GoAwayFrame
        response.error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
      else
        fail "Expected RST_STREAM or GOAWAY, got #{response.class}"
      end
    end

    pending "rejects second HEADERS frame without END_STREAM" do
      # TODO: The server should reject a second HEADERS frame on a stream that
      # already received headers without END_STREAM. This is a protocol error
      # per RFC 7540 Section 8.1
      client_socket = IO::Memory.new
      server_socket = IO::Memory.new

      # Write client preface
      client_socket.write(HT2::CONNECTION_PREFACE.to_slice)

      # Send SETTINGS
      settings = HT2::SettingsFrame.new
      settings.write_to(client_socket)

      # Send first HEADERS frame
      headers1 = encode_basic_headers("POST")
      send_headers_frame(client_socket, 1_u32, headers1, end_stream: false)

      # Send second HEADERS frame (protocol error)
      headers2 = encode_basic_headers("POST")
      send_headers_frame(client_socket, 1_u32, headers2, end_stream: false)

      # Reset for reading
      client_socket.rewind

      # Create server connection
      mock_socket = MockBidirectionalSocket.new(client_socket, server_socket)
      connection = HT2::Connection.new(mock_socket, is_server: true)

      # Set up on_headers handler that responds with 200 OK
      connection.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
        if end_stream
          response_headers = [
            {":status", "200"},
            {"content-type", "text/plain"},
          ]
          stream.send_headers(response_headers, end_stream: true)
        end
        nil
      end

      # Start connection processing
      spawn { connection.start rescue nil }

      # Wait for processing
      sleep 200.milliseconds

      # Read all available frames
      frames = read_all_frames(server_socket, timeout: 500.milliseconds)

      # Filter for RST_STREAM frames
      error_frames = frames.select { |f| f.is_a?(HT2::RstStreamFrame) }
      error_frames.should_not be_empty
      response = error_frames.first
      response.should be_a(HT2::RstStreamFrame)
      response.as(HT2::RstStreamFrame).error_code.should eq(HT2::ErrorCode::PROTOCOL_ERROR)
    end
  end

  describe "PRIORITY Frame" do
    it "accepts PRIORITY for idle stream and allows lower stream IDs" do
      client_socket = IO::Memory.new
      server_socket = IO::Memory.new

      # Write client preface
      client_socket.write(HT2::CONNECTION_PREFACE.to_slice)

      # Send SETTINGS
      settings = HT2::SettingsFrame.new
      settings.write_to(client_socket)

      # Send PRIORITY for stream 5 (idle)
      priority_data = HT2::PriorityData.new(
        stream_dependency: 0_u32,
        weight: 16_u8,
        exclusive: false
      )
      priority_frame = HT2::PriorityFrame.new(5_u32, priority_data)
      priority_frame.write_to(client_socket)

      # Now send HEADERS for stream 1 (lower ID)
      headers = encode_basic_headers("GET")
      send_headers_frame(client_socket, 1_u32, headers, end_stream: true)

      # Reset for reading
      client_socket.rewind

      # Create server connection
      mock_socket = MockBidirectionalSocket.new(client_socket, server_socket)
      connection = HT2::Connection.new(mock_socket, is_server: true)

      # Set up on_headers handler that responds with 200 OK
      connection.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
        if end_stream
          response_headers = [
            {":status", "200"},
            {"content-type", "text/plain"},
          ]
          stream.send_headers(response_headers, end_stream: true)
        end
        nil
      end

      # Start connection processing
      spawn { connection.start rescue nil }

      # Wait for processing
      sleep 200.milliseconds

      # Read all available frames
      frames = read_all_frames(server_socket, timeout: 500.milliseconds)

      # Should not receive an error (GOAWAY with NO_ERROR is OK, it's just closing)
      error_frames = frames.select do |f|
        case f
        when HT2::RstStreamFrame
          true
        when HT2::GoAwayFrame
          # Only consider it an error if it's not NO_ERROR
          f.error_code != HT2::ErrorCode::NO_ERROR
        else
          false
        end
      end

      if error_frames.any?
        fail "Server rejected lower stream ID after PRIORITY"
      end

      # Should have received HEADERS response
      header_frames = frames.select { |f| f.is_a?(HT2::HeadersFrame) }
      header_frames.should_not be_empty
    end
  end

  describe "CONTINUATION Frame" do
    it "accepts multiple CONTINUATION frames" do
      client_socket = IO::Memory.new
      server_socket = IO::Memory.new

      # Write client preface
      client_socket.write(HT2::CONNECTION_PREFACE.to_slice)

      # Send SETTINGS
      settings = HT2::SettingsFrame.new
      settings.write_to(client_socket)

      # Send HEADERS without END_HEADERS but with END_STREAM
      headers_part1 = Bytes[0x82] # :method GET
      headers_frame = HT2::HeadersFrame.new(1_u32, headers_part1, HT2::FrameFlags::END_STREAM)
      headers_frame.write_to(client_socket)

      # Send CONTINUATION frames
      cont1 = Bytes[0x87] # :scheme https
      cont_frame1 = HT2::ContinuationFrame.new(1_u32, cont1, HT2::FrameFlags::None)
      cont_frame1.write_to(client_socket)

      cont2 = Bytes[0x84] # :path /
      cont_frame2 = HT2::ContinuationFrame.new(1_u32, cont2, HT2::FrameFlags::None)
      cont_frame2.write_to(client_socket)

      # Final CONTINUATION with END_HEADERS (CONTINUATION can't have END_STREAM)
      cont3 = Bytes[0x01, 0x00] # :authority ""
      cont_frame3 = HT2::ContinuationFrame.new(1_u32, cont3, HT2::FrameFlags::END_HEADERS)
      cont_frame3.write_to(client_socket)

      # Reset for reading
      client_socket.rewind

      # Create server connection
      mock_socket = MockBidirectionalSocket.new(client_socket, server_socket)
      connection = HT2::Connection.new(mock_socket, is_server: true)

      # Set up on_headers handler that responds with 200 OK
      connection.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
        if end_stream
          response_headers = [
            {":status", "200"},
            {"content-type", "text/plain"},
          ]
          stream.send_headers(response_headers, end_stream: true)
        end
        nil
      end

      # Start connection processing
      spawn { connection.start rescue nil }

      # Wait for processing
      sleep 200.milliseconds

      # Read all available frames
      frames = read_all_frames(server_socket, timeout: 500.milliseconds)

      # Should get response headers, not error
      header_frames = frames.select { |f| f.is_a?(HT2::HeadersFrame) }
      header_frames.should_not be_empty
      header_frames.first.should be_a(HT2::HeadersFrame)
    end
  end

  describe "Trailers" do
    it "accepts POST request with trailers" do
      client_socket = IO::Memory.new
      server_socket = IO::Memory.new

      # Write client preface
      client_socket.write(HT2::CONNECTION_PREFACE.to_slice)

      # Send SETTINGS
      settings = HT2::SettingsFrame.new
      settings.write_to(client_socket)

      # Send HEADERS for POST
      headers = encode_basic_headers("POST")
      send_headers_frame(client_socket, 1_u32, headers, end_stream: false)

      # Send DATA
      data_frame = HT2::DataFrame.new(1_u32, "test data".to_slice, HT2::FrameFlags::None)
      data_frame.write_to(client_socket)

      # Send trailers as HEADERS with END_STREAM
      trailer_payload = Bytes[
        0x40,                                                 # Literal header with incremental indexing
        0x09,                                                 # Name length 9
        0x78, 0x2d, 0x74, 0x72, 0x61, 0x69, 0x6c, 0x65, 0x72, # "x-trailer"
        0x05,                                                 # Value length 5
        0x76, 0x61, 0x6c, 0x75, 0x65                          # "value"
      ]
      send_headers_frame(client_socket, 1_u32, trailer_payload, end_stream: true)

      # Reset for reading
      client_socket.rewind

      # Create server connection
      mock_socket = MockBidirectionalSocket.new(client_socket, server_socket)
      connection = HT2::Connection.new(mock_socket, is_server: true)

      # Set up on_headers handler that responds with 200 OK
      connection.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
        # Don't respond until we get the trailers (end_stream)
        nil
      end

      # Start connection processing
      spawn { connection.start rescue nil }

      # Wait for processing
      sleep 200.milliseconds

      # Read all available frames
      frames = read_all_frames(server_socket, timeout: 500.milliseconds)

      # Check for errors (GOAWAY with NO_ERROR is OK)
      frames.each do |frame|
        case frame
        when HT2::RstStreamFrame
          fail "Server rejected trailers with RST_STREAM"
        when HT2::GoAwayFrame
          if frame.error_code != HT2::ErrorCode::NO_ERROR
            fail "Server rejected trailers with GOAWAY: #{frame.error_code}"
          end
        end
      end

      # We're just checking the server didn't reject the trailers
      # It may or may not send a response
    end
  end
end

# Helper methods
private def send_headers_frame(socket : IO, stream_id : UInt32, payload : Bytes,
                               end_stream : Bool = false, end_headers : Bool = true)
  flags = HT2::FrameFlags::None
  flags = flags | HT2::FrameFlags::END_STREAM if end_stream
  flags = flags | HT2::FrameFlags::END_HEADERS if end_headers

  frame = HT2::HeadersFrame.new(stream_id, payload, flags)
  frame.write_to(socket)
  socket.flush if socket.responds_to?(:flush)
end

private def encode_basic_headers(method : String) : Bytes
  # Simple HPACK encoding for basic headers
  case method
  when "GET"
    # :method GET, :scheme https, :path /, :authority ""
    Bytes[0x82, 0x87, 0x84, 0x01, 0x00]
  when "POST"
    # :method POST, :scheme https, :path /, :authority ""
    Bytes[0x83, 0x87, 0x84, 0x01, 0x00]
  else
    raise "Unsupported method: #{method}"
  end
end

private def read_all_frames(socket : IO, timeout : Time::Span = 100.milliseconds) : Array(HT2::Frame)
  read_frames_until(socket, timeout) { false } # Never stop early
end

private def read_frames_until(socket : IO, timeout : Time::Span = 100.milliseconds, &block : HT2::Frame -> Bool) : Array(HT2::Frame)
  socket.rewind if socket.responds_to?(:rewind)

  frames = [] of HT2::Frame
  deadline = Time.monotonic + timeout
  buffer = Bytes.new(4096)
  accumulated = IO::Memory.new

  while Time.monotonic < deadline
    if socket.size > 0
      begin
        # Read available bytes
        bytes_read = socket.read(buffer)
        if bytes_read > 0
          accumulated.write(buffer[0, bytes_read])
          accumulated.rewind

          # Try to parse frames from accumulated data
          accumulated_bytes = accumulated.to_slice
          current_pos = 0

          while current_pos < accumulated_bytes.size
            remaining_bytes = accumulated_bytes[current_pos..-1]

            # Need at least 9 bytes for frame header
            break if remaining_bytes.size < 9

            begin
              # Read header to get frame length
              header_bytes = remaining_bytes[0..8]
              length = (header_bytes[0].to_u32 << 16) | (header_bytes[1].to_u32 << 8) | header_bytes[2].to_u32
              frame_size = 9 + length

              # Check if we have the full frame
              if remaining_bytes.size < frame_size
                # Not enough data for complete frame
                break
              end

              frame = HT2::Frame.parse(remaining_bytes)
              frames << frame
              current_pos += frame_size

              # Check if we found what we're looking for
              if yield frame
                return frames
              end
            rescue e
              # Skip this byte and try again
              current_pos += 1
            end
          end

          # Reset accumulated buffer to remaining unread data
          if current_pos < accumulated_bytes.size
            accumulated = IO::Memory.new
            accumulated.write(accumulated_bytes[current_pos..-1])
          else
            accumulated = IO::Memory.new
          end
        end
      rescue
        # Continue waiting
      end
    end
    sleep 10.milliseconds
  end

  frames
end
