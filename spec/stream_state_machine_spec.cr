require "./spec_helper"

describe HT2::StreamStateMachine do
  describe "#initialize" do
    it "starts in IDLE state by default" do
      machine = HT2::StreamStateMachine.new(1_u32)
      machine.current_state.should eq(HT2::StreamState::IDLE)
    end

    it "accepts initial state" do
      machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::OPEN)
      machine.current_state.should eq(HT2::StreamState::OPEN)
    end
  end

  describe "#transition" do
    context "from IDLE state" do
      it "transitions to OPEN on SendHeaders" do
        machine = HT2::StreamStateMachine.new(1_u32)
        new_state, warnings = machine.transition(HT2::StreamStateMachine::Event::SendHeaders)
        new_state.should eq(HT2::StreamState::OPEN)
        warnings.should be_empty
      end

      it "transitions to HALF_CLOSED_LOCAL on SendHeadersEndStream" do
        machine = HT2::StreamStateMachine.new(1_u32)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::SendHeadersEndStream)
        new_state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      end

      it "transitions to OPEN on ReceiveHeaders" do
        machine = HT2::StreamStateMachine.new(1_u32)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::ReceiveHeaders)
        new_state.should eq(HT2::StreamState::OPEN)
      end

      it "transitions to HALF_CLOSED_REMOTE on ReceiveHeadersEndStream" do
        machine = HT2::StreamStateMachine.new(1_u32)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::ReceiveHeadersEndStream)
        new_state.should eq(HT2::StreamState::HALF_CLOSED_REMOTE)
      end

      it "transitions to CLOSED on SendRstStream" do
        machine = HT2::StreamStateMachine.new(1_u32)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::SendRstStream)
        new_state.should eq(HT2::StreamState::CLOSED)
      end

      it "rejects SendData" do
        machine = HT2::StreamStateMachine.new(1_u32)
        expect_raises(HT2::ProtocolError, /not allowed/) do
          machine.transition(HT2::StreamStateMachine::Event::SendData)
        end
      end
    end

    context "from OPEN state" do
      it "transitions to HALF_CLOSED_LOCAL on SendDataEndStream" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::OPEN)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::SendDataEndStream)
        new_state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      end

      it "transitions to HALF_CLOSED_REMOTE on ReceiveDataEndStream" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::OPEN)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::ReceiveDataEndStream)
        new_state.should eq(HT2::StreamState::HALF_CLOSED_REMOTE)
      end

      it "stays in OPEN on SendData" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::OPEN)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::SendData)
        new_state.should eq(HT2::StreamState::OPEN)
      end

      it "transitions to CLOSED on SendRstStream" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::OPEN)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::SendRstStream)
        new_state.should eq(HT2::StreamState::CLOSED)
      end

      it "warns about trailers when receiving headers" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::OPEN)
        new_state, warnings = machine.transition(HT2::StreamStateMachine::Event::SendHeaders)
        warnings.should contain("Headers in OPEN state are likely trailers")
      end
    end

    context "from HALF_CLOSED_LOCAL state" do
      it "transitions to CLOSED on ReceiveDataEndStream" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::HALF_CLOSED_LOCAL)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::ReceiveDataEndStream)
        new_state.should eq(HT2::StreamState::CLOSED)
      end

      it "transitions to CLOSED on ReceiveHeadersEndStream" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::HALF_CLOSED_LOCAL)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::ReceiveHeadersEndStream)
        new_state.should eq(HT2::StreamState::CLOSED)
      end

      it "stays in HALF_CLOSED_LOCAL on ReceiveData" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::HALF_CLOSED_LOCAL)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::ReceiveData)
        new_state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      end

      it "rejects SendData" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::HALF_CLOSED_LOCAL)
        expect_raises(HT2::ProtocolError, /not allowed/) do
          machine.transition(HT2::StreamStateMachine::Event::SendData)
        end
      end
    end

    context "from HALF_CLOSED_REMOTE state" do
      it "transitions to CLOSED on SendDataEndStream" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::HALF_CLOSED_REMOTE)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::SendDataEndStream)
        new_state.should eq(HT2::StreamState::CLOSED)
      end

      it "transitions to CLOSED on SendHeadersEndStream" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::HALF_CLOSED_REMOTE)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::SendHeadersEndStream)
        new_state.should eq(HT2::StreamState::CLOSED)
      end

      it "stays in HALF_CLOSED_REMOTE on SendData" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::HALF_CLOSED_REMOTE)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::SendData)
        new_state.should eq(HT2::StreamState::HALF_CLOSED_REMOTE)
      end

      it "rejects ReceiveData" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::HALF_CLOSED_REMOTE)
        expect_raises(HT2::ProtocolError, /not allowed/) do
          machine.transition(HT2::StreamStateMachine::Event::ReceiveData)
        end
      end
    end

    context "from CLOSED state" do
      it "rejects all events" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::CLOSED)

        expect_raises(HT2::StreamClosedError, /closed/) do
          machine.transition(HT2::StreamStateMachine::Event::SendHeaders)
        end

        expect_raises(HT2::StreamClosedError, /closed/) do
          machine.transition(HT2::StreamStateMachine::Event::ReceiveData)
        end
      end
    end

    context "from RESERVED_LOCAL state" do
      it "transitions to HALF_CLOSED_REMOTE on SendHeaders" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::RESERVED_LOCAL)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::SendHeaders)
        new_state.should eq(HT2::StreamState::HALF_CLOSED_REMOTE)
      end

      it "transitions to CLOSED on SendRstStream" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::RESERVED_LOCAL)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::SendRstStream)
        new_state.should eq(HT2::StreamState::CLOSED)
      end

      it "rejects ReceiveHeaders" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::RESERVED_LOCAL)
        expect_raises(HT2::ProtocolError, /not allowed/) do
          machine.transition(HT2::StreamStateMachine::Event::ReceiveHeaders)
        end
      end
    end

    context "from RESERVED_REMOTE state" do
      it "transitions to HALF_CLOSED_LOCAL on ReceiveHeaders" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::RESERVED_REMOTE)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::ReceiveHeaders)
        new_state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)
      end

      it "transitions to CLOSED on ReceiveRstStream" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::RESERVED_REMOTE)
        new_state, _ = machine.transition(HT2::StreamStateMachine::Event::ReceiveRstStream)
        new_state.should eq(HT2::StreamState::CLOSED)
      end

      it "rejects SendHeaders" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::RESERVED_REMOTE)
        expect_raises(HT2::ProtocolError, /not allowed/) do
          machine.transition(HT2::StreamStateMachine::Event::SendHeaders)
        end
      end
    end
  end

  describe "#can_handle?" do
    it "checks if event is allowed without transitioning" do
      machine = HT2::StreamStateMachine.new(1_u32)

      machine.can_handle?(HT2::StreamStateMachine::Event::SendHeaders).should be_true
      machine.can_handle?(HT2::StreamStateMachine::Event::SendData).should be_false

      # State should not have changed
      machine.current_state.should eq(HT2::StreamState::IDLE)
    end
  end

  describe ".headers_event" do
    it "returns correct event for sending headers" do
      event = HT2::StreamStateMachine.headers_event(false, true)
      event.should eq(HT2::StreamStateMachine::Event::SendHeaders)

      event = HT2::StreamStateMachine.headers_event(true, true)
      event.should eq(HT2::StreamStateMachine::Event::SendHeadersEndStream)
    end

    it "returns correct event for receiving headers" do
      event = HT2::StreamStateMachine.headers_event(false, false)
      event.should eq(HT2::StreamStateMachine::Event::ReceiveHeaders)

      event = HT2::StreamStateMachine.headers_event(true, false)
      event.should eq(HT2::StreamStateMachine::Event::ReceiveHeadersEndStream)
    end
  end

  describe ".data_event" do
    it "returns correct event for sending data" do
      event = HT2::StreamStateMachine.data_event(false, true)
      event.should eq(HT2::StreamStateMachine::Event::SendData)

      event = HT2::StreamStateMachine.data_event(true, true)
      event.should eq(HT2::StreamStateMachine::Event::SendDataEndStream)
    end

    it "returns correct event for receiving data" do
      event = HT2::StreamStateMachine.data_event(false, false)
      event.should eq(HT2::StreamStateMachine::Event::ReceiveData)

      event = HT2::StreamStateMachine.data_event(true, false)
      event.should eq(HT2::StreamStateMachine::Event::ReceiveDataEndStream)
    end
  end

  describe ".rst_stream_event" do
    it "returns correct event for sending RST_STREAM" do
      event = HT2::StreamStateMachine.rst_stream_event(true)
      event.should eq(HT2::StreamStateMachine::Event::SendRstStream)
    end

    it "returns correct event for receiving RST_STREAM" do
      event = HT2::StreamStateMachine.rst_stream_event(false)
      event.should eq(HT2::StreamStateMachine::Event::ReceiveRstStream)
    end
  end

  describe "validation methods" do
    describe "#validate_send_headers" do
      it "allows sending headers in IDLE state" do
        machine = HT2::StreamStateMachine.new(1_u32)
        machine.validate_send_headers # Should not raise
      end

      it "rejects sending headers in CLOSED state" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::CLOSED)
        expect_raises(HT2::StreamClosedError, /Cannot send headers on closed stream/) do
          machine.validate_send_headers
        end
      end

      it "rejects sending headers in HALF_CLOSED_LOCAL state" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::HALF_CLOSED_LOCAL)
        expect_raises(HT2::StreamError, /Cannot send headers in state/) do
          machine.validate_send_headers
        end
      end
    end

    describe "#validate_send_data" do
      it "allows sending data in OPEN state" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::OPEN)
        machine.validate_send_data # Should not raise
      end

      it "rejects sending data in IDLE state" do
        machine = HT2::StreamStateMachine.new(1_u32)
        expect_raises(HT2::ProtocolError, /Cannot send data in state/) do
          machine.validate_send_data
        end
      end

      it "rejects sending data in CLOSED state" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::CLOSED)
        expect_raises(HT2::StreamClosedError, /Cannot send data on closed stream/) do
          machine.validate_send_data
        end
      end
    end

    describe "#validate_receive_headers" do
      it "allows receiving headers in IDLE state" do
        machine = HT2::StreamStateMachine.new(1_u32)
        machine.validate_receive_headers # Should not raise
      end

      it "rejects receiving headers in CLOSED state" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::CLOSED)
        expect_raises(HT2::StreamClosedError, /Cannot receive headers on closed stream/) do
          machine.validate_receive_headers
        end
      end
    end

    describe "#validate_receive_data" do
      it "allows receiving data in OPEN state" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::OPEN)
        machine.validate_receive_data # Should not raise
      end

      it "rejects receiving data in IDLE state" do
        machine = HT2::StreamStateMachine.new(1_u32)
        expect_raises(HT2::ProtocolError, /Cannot receive data in IDLE state/) do
          machine.validate_receive_data
        end
      end

      it "rejects receiving data in CLOSED state" do
        machine = HT2::StreamStateMachine.new(1_u32, HT2::StreamState::CLOSED)
        expect_raises(HT2::StreamClosedError, /Cannot receive data on closed stream/) do
          machine.validate_receive_data
        end
      end
    end
  end

  describe "complex state transitions" do
    it "handles complete stream lifecycle" do
      machine = HT2::StreamStateMachine.new(1_u32)

      # Client sends headers
      machine.transition(HT2::StreamStateMachine::Event::SendHeaders)
      machine.current_state.should eq(HT2::StreamState::OPEN)

      # Server sends headers
      machine.transition(HT2::StreamStateMachine::Event::ReceiveHeaders)
      machine.current_state.should eq(HT2::StreamState::OPEN)

      # Client sends data
      machine.transition(HT2::StreamStateMachine::Event::SendData)
      machine.current_state.should eq(HT2::StreamState::OPEN)

      # Client ends stream
      machine.transition(HT2::StreamStateMachine::Event::SendDataEndStream)
      machine.current_state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)

      # Server sends response data
      machine.transition(HT2::StreamStateMachine::Event::ReceiveData)
      machine.current_state.should eq(HT2::StreamState::HALF_CLOSED_LOCAL)

      # Server ends stream
      machine.transition(HT2::StreamStateMachine::Event::ReceiveDataEndStream)
      machine.current_state.should eq(HT2::StreamState::CLOSED)
    end

    it "handles RST_STREAM from any state" do
      states = [
        HT2::StreamState::IDLE,
        HT2::StreamState::OPEN,
        HT2::StreamState::HALF_CLOSED_LOCAL,
        HT2::StreamState::HALF_CLOSED_REMOTE,
        HT2::StreamState::RESERVED_LOCAL,
        HT2::StreamState::RESERVED_REMOTE,
      ]

      states.each do |state|
        machine = HT2::StreamStateMachine.new(1_u32, state)
        machine.transition(HT2::StreamStateMachine::Event::SendRstStream)
        machine.current_state.should eq(HT2::StreamState::CLOSED)
      end
    end
  end
end
