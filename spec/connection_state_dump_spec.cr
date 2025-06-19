require "./spec_helper"

describe HT2::Connection do
  describe "#dump_state" do
    it "dumps comprehensive connection state" do
      server_io, client_io = IO::Memory.new, IO::Memory.new
      connection = HT2::Connection.new(server_io, is_server: true)

      # Get state dump
      state_dump = connection.dump_state

      # Verify key sections are present
      state_dump.should contain("=== HTTP/2 Connection State Dump ===")
      state_dump.should contain("=== Connection State ===")
      state_dump.should contain("=== Settings ===")
      state_dump.should contain("=== Streams")
      state_dump.should contain("=== Flow Control ===")
      state_dump.should contain("=== Backpressure ===")
      state_dump.should contain("=== Buffer Management ===")
      state_dump.should contain("=== HPACK State ===")
      state_dump.should contain("=== Metrics Summary ===")
      state_dump.should contain("=== Security Status ===")

      # Verify connection type
      state_dump.should contain("Type: Server")

      # Verify status
      state_dump.should contain("Status: Active")

      # Verify HPACK information
      state_dump.should contain("Encoder Table Size:")
      state_dump.should contain("Decoder Table Size:")

      # Verify flow control
      state_dump.should contain("Strategy:")
      state_dump.should contain("Initial Window:")

      # Verify metrics
      state_dump.should contain("Streams:")
      state_dump.should contain("Bytes:")
      state_dump.should contain("Frames Sent:")
      state_dump.should contain("Frames Received:")
    end

    it "shows closed connection status" do
      server_io, client_io = IO::Memory.new, IO::Memory.new
      connection = HT2::Connection.new(server_io, is_server: true)
      connection.close

      state_dump = connection.dump_state
      state_dump.should contain("Status: Closed")
      state_dump.should contain("Closed: true")
    end

    it "shows stream information when streams exist" do
      server_io, client_io = IO::Memory.new, IO::Memory.new
      connection = HT2::Connection.new(server_io, is_server: true)

      # Create a test stream
      stream = connection.test_get_or_create_stream(1_u32)

      state_dump = connection.dump_state
      state_dump.should contain("Stream 1:")
      state_dump.should contain("State:")
      state_dump.should contain("Send Window:")
      state_dump.should contain("Recv Window:")
    end
  end
end
