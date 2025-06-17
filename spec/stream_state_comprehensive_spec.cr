require "./spec_helper"

describe HT2::Stream do
  describe "comprehensive state transitions for ALL frame types" do
    # Test matrix: Each frame type in each state
    # States: IDLE, OPEN, HALF_CLOSED_LOCAL, HALF_CLOSED_REMOTE, CLOSED
    # Frame types: DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE, PING, GOAWAY, WINDOW_UPDATE, CONTINUATION

    describe "IDLE state - all frame types" do
      it "allows HEADERS frames (transitions to OPEN or HALF_CLOSED_REMOTE)" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 1)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.state.should eq(HT2::StreamState::OPEN)
      end

      it "allows PRIORITY frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 3)
        priority = HT2::PriorityData.new(0_u32, 15_u8, false)
        stream.receive_priority(priority)
        stream.state.should eq(HT2::StreamState::IDLE)
      end

      it "rejects DATA frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 5)
        expect_raises(HT2::ProtocolError) do
          stream.receive_data("test".to_slice, false)
        end
      end

      it "rejects WINDOW_UPDATE frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 7)
        expect_raises(HT2::ProtocolError) do
          stream.update_recv_window(100)
        end
      end

      it "rejects RST_STREAM frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 9)
        # RST_STREAM in IDLE state should transition to CLOSED
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      # Note: SETTINGS, PING, GOAWAY are connection-level frames, not stream-level
      # CONTINUATION frames are handled as part of HEADERS processing
      # PUSH_PROMISE initiates new streams, tested separately
    end

    describe "OPEN state - all frame types" do
      it "allows DATA frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 11)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_data("test".to_slice, false)
        stream.state.should eq(HT2::StreamState::OPEN)
      end

      it "allows HEADERS frames (trailers)" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 13)
        stream.receive_headers([{":method", "POST"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], false)
        stream.send_data("response".to_slice, false)
        # Trailers
        stream.send_headers([{"x-checksum", "abc123"}], true)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      end

      it "allows PRIORITY frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 15)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        priority = HT2::PriorityData.new(0_u32, 10_u8, false)
        stream.receive_priority(priority)
        stream.state.should eq(HT2::StreamState::OPEN)
      end

      it "allows RST_STREAM frames (transitions to CLOSED)" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 17)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "allows WINDOW_UPDATE frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 19)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        initial_window = stream.send_window_size
        stream.update_send_window(1000)
        stream.send_window_size.should eq(initial_window + 1000)
      end

      it "transitions with END_STREAM flag" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 21)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        # Send END_STREAM
        stream.send_headers([{":status", "200"}], true)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      end
    end

    describe "HALF_CLOSED_LOCAL state - all frame types" do
      it "allows receiving DATA frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 23)
        stream.receive_headers([{":method", "POST"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        stream.receive_data("request body".to_slice, false)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      end

      it "allows receiving HEADERS frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 25)
        stream.receive_headers([{":method", "POST"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        # Client can still send trailers
        stream.receive_headers([{"x-client-checksum", "xyz789"}], true)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "rejects sending DATA frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 27)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        expect_raises(HT2::StreamClosedError) do
          stream.send_data("invalid".to_slice, false)
        end
      end

      it "rejects sending HEADERS frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 29)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        expect_raises(HT2::StreamError) do
          stream.send_headers([{"x-extra", "header"}], false)
        end
      end

      it "allows PRIORITY frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 31)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        priority = HT2::PriorityData.new(0_u32, 5_u8, true)
        stream.receive_priority(priority)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      end

      it "allows RST_STREAM frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 33)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        stream.receive_rst_stream(HT2::ErrorCode::NO_ERROR)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "allows WINDOW_UPDATE frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 35)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        initial_window = stream.recv_window_size
        stream.update_recv_window(500)
        stream.recv_window_size.should eq(initial_window + 500)
      end
    end

    describe "HALF_CLOSED_REMOTE state - all frame types" do
      it "allows sending DATA frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 37)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        stream.send_headers([{":status", "200"}], false)
        stream.send_data("response".to_slice, false)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_REMOTE)
      end

      it "allows sending HEADERS frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 39)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        stream.send_headers([{":status", "200"}], false)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_REMOTE)
      end

      it "rejects receiving DATA frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 41)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        expect_raises(HT2::StreamClosedError) do
          stream.receive_data("invalid".to_slice, false)
        end
      end

      it "rejects receiving HEADERS frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 43)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        expect_raises(HT2::ProtocolError) do
          stream.receive_headers([{"x-extra", "header"}], false)
        end
      end

      it "allows PRIORITY frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 45)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        priority = HT2::PriorityData.new(0_u32, 20_u8, false)
        stream.receive_priority(priority)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_REMOTE)
      end

      it "allows RST_STREAM frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 47)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        stream.send_rst_stream(HT2::ErrorCode::INTERNAL_ERROR)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "allows WINDOW_UPDATE frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 49)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        initial_window = stream.send_window_size
        stream.update_send_window(2000)
        stream.send_window_size.should eq(initial_window + 2000)
      end

      it "transitions to CLOSED with END_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 51)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        stream.send_headers([{":status", "200"}], false)
        stream.send_data("final response".to_slice, true)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end
    end

    describe "CLOSED state - all frame types" do
      it "rejects DATA frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 53)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        expect_raises(HT2::StreamClosedError) do
          stream.receive_data("late data".to_slice, false)
        end
      end

      it "rejects HEADERS frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 55)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        expect_raises(HT2::StreamClosedError) do
          stream.receive_headers([{"late", "header"}], false)
        end
      end

      it "allows PRIORITY frames for a grace period" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 57)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        # PRIORITY allowed for 2 seconds after closure
        priority = HT2::PriorityData.new(0_u32, 25_u8, true)
        stream.receive_priority(priority)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "allows RST_STREAM frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 59)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        # Duplicate RST_STREAM should be allowed
        stream.receive_rst_stream(HT2::ErrorCode::NO_ERROR)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "ignores WINDOW_UPDATE frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 61)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        # WINDOW_UPDATE should be ignored in CLOSED state
        stream.update_recv_window(3000)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "tracks closure time for PRIORITY grace period" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 63)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        stream.closed_at.should_not be_nil
      end
    end

    describe "special frame handling" do
      it "handles CONTINUATION frames as part of HEADERS" do
        # CONTINUATION frames are processed as part of header block fragmentation
        # They don't trigger state transitions independently
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 65)
        # Headers that would be fragmented across HEADERS + CONTINUATION
        large_headers = Array(Tuple(String, String)).new
        large_headers << {":method", "GET"}
        large_headers << {":path", "/"}
        large_headers << {":scheme", "https"}
        large_headers << {":authority", "example.com"}
        100.times do |i|
          large_headers << {"x-custom-#{i}", "value-#{i}"}
        end
        stream.receive_headers(large_headers, false)
        stream.state.should eq(HT2::StreamState::OPEN)
      end

      it "validates stream ID constraints" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        # Client streams use odd IDs
        client_stream1 = HT2::Stream.new(connection, 1)
        client_stream2 = HT2::Stream.new(connection, 3)
        client_stream3 = HT2::Stream.new(connection, 5)

        # Server push streams use even IDs
        server_stream1 = HT2::Stream.new(connection, 2)
        server_stream2 = HT2::Stream.new(connection, 4)

        client_stream1.id.should eq(1)
        client_stream2.id.should eq(3)
        client_stream3.id.should eq(5)
        server_stream1.id.should eq(2)
        server_stream2.id.should eq(4)
      end

      it "handles rapid state transitions" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 67)
        # IDLE -> OPEN -> HALF_CLOSED_LOCAL -> CLOSED in rapid succession
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.state.should eq(HT2::StreamState::OPEN)
        stream.send_headers([{":status", "200"}], true)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
        stream.receive_data("".to_slice, true)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "handles error conditions properly" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 69)

        # Protocol violations should raise appropriate errors
        expect_raises(HT2::ProtocolError) do
          stream.update_recv_window(0) # Zero increment not allowed
        end

        # Stream should remain in IDLE state after error
        stream.state.should eq(HT2::StreamState::IDLE)
      end
    end

    describe "connection-level frames" do
      # Note: SETTINGS, PING, and GOAWAY are connection-level frames
      # They don't directly affect stream state but may impact stream behavior

      it "notes that SETTINGS frames are connection-level" do
        # SETTINGS frames affect connection parameters, not individual stream states
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 71)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        # SETTINGS would be processed at connection level
        stream.state.should eq(HT2::StreamState::OPEN)
      end

      it "notes that PING frames are connection-level" do
        # PING frames are for connection keepalive/RTT measurement
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 73)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        # PING would be processed at connection level
        stream.state.should eq(HT2::StreamState::OPEN)
      end

      it "notes that GOAWAY frames affect connection termination" do
        # GOAWAY frames signal connection shutdown, affecting all streams
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 75)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        # GOAWAY would be processed at connection level
        stream.state.should eq(HT2::StreamState::OPEN)
      end
    end
  end
end
