require "./spec_helper"

# This helper provides a framework for testing HTTP/2 protocol compliance
# using in-memory IO objects to simulate a client-server connection.
# This allows for fine-grained control over the frame exchange without
# the overhead of a full TCP server.
module ProtocolComplianceSpec
  @@debug_log_file : File? = nil

  def self.open_debug_log
    unless @@debug_log_file
      begin
        @@debug_log_file = File.open("test_debug.log", "a")
      rescue File::Error
        # If test_debug.log is a directory or can't be opened, use /tmp/test_debug.log
        @@debug_log_file = File.open("/tmp/test_debug.log", "a")
      end
    end
  end

  def self.close_debug_log
    if log_file = @@debug_log_file
      log_file.close
      @@debug_log_file = nil
    end
  end

  def self.debug_log_file : File?
    @@debug_log_file
  end

  class TestConnection
    getter client_io : MockBidirectionalSocket
    getter server_io : MockBidirectionalSocket
    getter connection : HT2::Connection
    getter ready : Channel(Nil)
    getter frame_received : Channel(HT2::Frame)
    getter processed : Channel(Nil)
    property on_client_headers_received : Proc(HT2::Stream, Nil)?

    def initialize(handler : HT2::Server::Handler)
      ProtocolComplianceSpec.open_debug_log
      @client_io = MockBidirectionalSocket.new
      @server_io = MockBidirectionalSocket.new
      @frame_received = Channel(HT2::Frame).new
      @ready = Channel(Nil).new
      @processed = Channel(Nil).new

      @connection = HT2::Connection.new(@server_io, is_server: true)
      @connection.on_headers = ->(stream : HT2::Stream, headers : Array(Tuple(String, String)), end_stream : Bool) do
        # Allow test to inspect stream before default handler processes it
        @on_client_headers_received.try(&.call(stream))

        if end_stream
          request = HT2::Request.from_stream(stream)
          response = HT2::Response.new(stream)
          handler.call(request, response)
          response.close unless response.closed?
        end
      end
      @connection.on_data = ->(stream : HT2::Stream, data : Bytes, end_stream : Bool) do
        if end_stream
          request = HT2::Request.from_stream(stream)
          response = HT2::Response.new(stream)
          handler.call(request, response)
          response.close unless response.closed?
        end
      end
      @connection.on_frame_processed = ->(frame : HT2::Frame) do
        @frame_received.send(frame)
        @processed.send(nil)
      end
    end

    def start_server
      spawn do
        # Server reads client preface
        preface_buffer = Bytes.new(HT2::CONNECTION_PREFACE.bytesize)
        @server_io.read(preface_buffer)

        # Start the connection (sends initial SETTINGS)
        @connection.start_without_preface
        @ready.send(nil)
        @connection.read_loop
      end
    end

    def send_client_preface
      @client_io.write(HT2::CONNECTION_PREFACE.to_slice)
    end

    def send_frame(frame : HT2::Frame)
      @client_io.write(frame.to_bytes)
      @processed.receive
    end

    def expect_frame(frame_type : HT2::FrameType, timeout = 5.seconds) : HT2::Frame
      start_time = Time.monotonic
      loop do
        remaining_time = timeout - (Time.monotonic - start_time)
        raise "Timeout waiting for frame #{frame_type}" if remaining_time <= 0.seconds

        select
        when frame = @frame_received.receive
          if frame.is_a?(HT2::UnknownFrame)
            unknown_frame = frame.as(HT2::UnknownFrame)
            if log_file = ProtocolComplianceSpec.debug_log_file
              log_file.puts "DEBUG: expect_frame received UnknownFrame! Expected: #{frame_type}"
              log_file.puts "DEBUG: UnknownFrame type: #{unknown_frame.unknown_type.value.to_s(16)}"
              log_file.puts "DEBUG: UnknownFrame payload: #{unknown_frame.payload_data.hexstring}"
            end
            # If it's an UnknownFrame and not what we expect, raise an error to fail fast
            raise "Received unexpected UnknownFrame (type: #{unknown_frame.unknown_type.value.to_s(16)}) while expecting #{frame_type}"
          end
          if log_file = ProtocolComplianceSpec.debug_log_file
            log_file.puts "DEBUG: expect_frame received frame type: #{frame.type}, expected: #{frame_type}"
            log_file.puts "DEBUG: expect_frame received frame raw: #{frame.to_bytes.hexstring}"
          end
          return frame if frame.type == frame_type
        when timeout(remaining_time)
          raise "Timeout waiting for frame #{frame_type}"
        end
      end
    end

    def close
      @connection.close
      @client_io.close
      @server_io.close
      ProtocolComplianceSpec.close_debug_log
    end
  end

  def with_test_connection(&block)
    handler = ->(req : HT2::Request, res : HT2::Response) do
      res.headers["content-type"] = "text/plain"
      res.write "Hello"
    end

    conn = TestConnection.new(handler)

    begin
      # Perform handshake
      conn.send_client_preface
      conn.start_server
      conn.ready.receive

      # Client receives server SETTINGS
      settings_frame = conn.expect_frame(HT2::FrameType::SETTINGS)
      settings_frame.should be_a(HT2::SettingsFrame)

      # Client sends its SETTINGS frame
      client_settings = HT2::SettingsFrame.new
      conn.send_frame(client_settings)

      # Client sends SETTINGS ACK
      ack = HT2::SettingsFrame.new(flags: HT2::FrameFlags::ACK)
      conn.send_frame(ack)

      yield conn
    ensure
      conn.close
      ProtocolComplianceSpec.close_debug_log
    end
  end
end
