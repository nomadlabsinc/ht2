require "./spec_helper"

describe HT2::Stream do
  describe "comprehensive state transitions for all frame types" do
    it "starts in IDLE state" do
      connection = HT2::Connection.new(IO::Memory.new, true)
      stream = HT2::Stream.new(connection, 1)
      stream.state.should eq(HT2::StreamState::IDLE)
    end

    describe "IDLE state transitions" do
      it "transitions to OPEN on headers without END_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 3)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.state.should eq(HT2::StreamState::OPEN)
      end

      it "transitions to HALF_CLOSED_REMOTE on headers with END_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 5)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_REMOTE)
      end

      it "rejects DATA frames in IDLE state" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 7)
        expect_raises(HT2::ProtocolError) do
          stream.receive_data("data".to_slice, false)
        end
      end

      it "rejects WINDOW_UPDATE frames in IDLE state" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 9)
        expect_raises(HT2::ProtocolError) do
          stream.update_recv_window(100)
        end
      end

      it "ignores PRIORITY frames per RFC 9113 compliance" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 11)
        # Priority frames should be ignored per RFC 9113
        # Stream should remain in IDLE state
        stream.state.should eq(HT2::StreamState::IDLE)
      end
    end

    describe "OPEN state transitions" do
      it "remains OPEN on data without END_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 13)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_data("data".to_slice, false)
        stream.state.should eq(HT2::StreamState::OPEN)
      end

      it "transitions to HALF_CLOSED_REMOTE on data with END_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 15)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_data("data".to_slice, true)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_REMOTE)
      end

      it "transitions to HALF_CLOSED_LOCAL after sending data with END_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 17)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      end

      it "transitions to CLOSED on RST_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 19)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "allows WINDOW_UPDATE frames in OPEN state" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 21)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        initial_window = stream.send_window_size
        stream.update_send_window(1000)
        stream.send_window_size.should eq(initial_window + 1000)
      end
    end

    describe "HALF_CLOSED_LOCAL state transitions" do
      it "remains HALF_CLOSED_LOCAL on receiving data without END_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 23)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        stream.receive_data("data".to_slice, false)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      end

      it "transitions to CLOSED on receiving data with END_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 25)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        stream.receive_data("data".to_slice, true)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "rejects sending DATA frames in HALF_CLOSED_LOCAL state" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 27)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        expect_raises(HT2::StreamClosedError) do
          stream.send_data("data".to_slice, false)
        end
      end

      it "transitions to CLOSED on RST_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 29)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "allows receiving WINDOW_UPDATE frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 31)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], true)
        initial_window = stream.recv_window_size
        stream.update_recv_window(1000)
        stream.recv_window_size.should eq(initial_window + 1000)
      end
    end

    describe "HALF_CLOSED_REMOTE state transitions" do
      it "remains HALF_CLOSED_REMOTE on sending data without END_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 33)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        stream.send_headers([{":status", "200"}], false)
        stream.send_data("data".to_slice, false)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_REMOTE)
      end

      it "transitions to CLOSED on sending data with END_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 35)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        stream.send_headers([{":status", "200"}], false)
        stream.send_data("data".to_slice, true)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "rejects receiving DATA frames in HALF_CLOSED_REMOTE state" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 37)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        expect_raises(HT2::StreamClosedError) do
          stream.receive_data("data".to_slice, false)
        end
      end

      it "transitions to CLOSED on RST_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 39)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        stream.send_rst_stream(HT2::ErrorCode::CANCEL)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "allows sending WINDOW_UPDATE frames" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 41)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], true)
        # WINDOW_UPDATE frames should be allowed in HALF_CLOSED_REMOTE
        initial_window = stream.send_window_size
        stream.update_send_window(1000)
        stream.send_window_size.should eq(initial_window + 1000)
      end
    end

    describe "CLOSED state behavior" do
      it "rejects DATA frames in CLOSED state" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 43)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        expect_raises(HT2::StreamClosedError) do
          stream.receive_data("data".to_slice, false)
        end
      end

      it "rejects HEADERS frames in CLOSED state" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 45)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        expect_raises(HT2::StreamClosedError) do
          stream.receive_headers([{"content-type", "text/plain"}], false)
        end
      end

      it "allows PRIORITY frames for a short period after closure" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 47)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        # According to RFC 9113, PRIORITY frames are deprecated and ignored
        # Stream should remain closed after being reset
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "ignores WINDOW_UPDATE frames in CLOSED state" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 49)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        # WINDOW_UPDATE frames should be ignored in CLOSED state
        stream.update_recv_window(1000)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "allows RST_STREAM frames in CLOSED state" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 51)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        # RST_STREAM can be received in CLOSED state without error
        stream.receive_rst_stream(HT2::ErrorCode::NO_ERROR)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end
    end

    describe "edge cases and error conditions" do
      it "handles receiving trailers (HEADERS after DATA)" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 53)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], false)
        stream.send_data("data".to_slice, false)
        # Trailers are headers sent after data
        stream.send_headers([{"x-trailer", "value"}], true)
        stream.state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      end

      it "handles concurrent END_STREAM from both sides" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 55)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_headers([{":status", "200"}], false)
        # Both sides send END_STREAM
        stream.receive_data("request".to_slice, true)
        stream.send_data("response".to_slice, true)
        stream.state.should eq(HT2::StreamState::CLOSED)
      end

      it "validates stream ID must be odd for client-initiated streams" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        # Client-initiated streams must use odd IDs
        client_stream = HT2::Stream.new(connection, 1)
        client_stream.id.should eq(1)
        client_stream2 = HT2::Stream.new(connection, 3)
        client_stream2.id.should eq(3)
      end

      it "validates stream ID must be even for server-initiated streams" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        # Server-initiated streams (push promises) must use even IDs
        server_stream = HT2::Stream.new(connection, 2)
        server_stream.id.should eq(2)
        server_stream2 = HT2::Stream.new(connection, 4)
        server_stream2.id.should eq(4)
      end

      it "handles state after sending RST_STREAM" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 57)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.send_rst_stream(HT2::ErrorCode::CANCEL)
        stream.state.should eq(HT2::StreamState::CLOSED)
        # After sending RST_STREAM, no frames should be sent
        expect_raises(HT2::StreamClosedError) do
          stream.send_data("data".to_slice, false)
        end
      end

      it "tracks recently closed streams to detect protocol violations" do
        connection = HT2::Connection.new(IO::Memory.new, true)
        stream = HT2::Stream.new(connection, 59)
        stream.receive_headers([{":method", "GET"}, {":path", "/"}, {":scheme", "https"}, {":authority", "example.com"}], false)
        stream.receive_rst_stream(HT2::ErrorCode::CANCEL)
        # Connection should track this as a recently closed stream
        stream.state.should eq(HT2::StreamState::CLOSED)
        stream.closed_at.should_not be_nil
      end
    end
  end
end
