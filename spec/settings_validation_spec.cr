require "./spec_helper"

describe HT2::Connection do
  describe "settings validation" do
    it "validates settings through update_settings method" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, true)

      # Test valid ENABLE_PUSH values
      settings = HT2::SettingsFrame::Settings.new
      settings[HT2::SettingsParameter::ENABLE_PUSH] = 0_u32
      connection.update_settings(settings) # Should not raise

      settings[HT2::SettingsParameter::ENABLE_PUSH] = 1_u32
      connection.update_settings(settings) # Should not raise

      # Test invalid ENABLE_PUSH value
      expect_raises(HT2::ConnectionError) do
        settings[HT2::SettingsParameter::ENABLE_PUSH] = 2_u32
        connection.update_settings(settings)
      end

      # Test valid INITIAL_WINDOW_SIZE
      settings = HT2::SettingsFrame::Settings.new
      settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE] = 65535_u32
      connection.update_settings(settings) # Should not raise

      settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE] = 0x7FFFFFFF_u32
      connection.update_settings(settings) # Should not raise

      # Test invalid INITIAL_WINDOW_SIZE
      expect_raises(HT2::ConnectionError) do
        settings[HT2::SettingsParameter::INITIAL_WINDOW_SIZE] = 0x80000000_u32
        connection.update_settings(settings)
      end

      # Test valid MAX_FRAME_SIZE values
      settings = HT2::SettingsFrame::Settings.new
      settings[HT2::SettingsParameter::MAX_FRAME_SIZE] = 16_384_u32
      connection.update_settings(settings) # Should not raise

      settings[HT2::SettingsParameter::MAX_FRAME_SIZE] = 16_777_215_u32
      connection.update_settings(settings) # Should not raise

      # Test invalid MAX_FRAME_SIZE values
      expect_raises(HT2::ConnectionError) do
        settings[HT2::SettingsParameter::MAX_FRAME_SIZE] = 16_383_u32
        connection.update_settings(settings)
      end

      expect_raises(HT2::ConnectionError) do
        settings[HT2::SettingsParameter::MAX_FRAME_SIZE] = 16_777_216_u32
        connection.update_settings(settings)
      end
    end
  end

  describe "settings updates" do
    it "updates local settings" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, true)

      settings = HT2::SettingsFrame::Settings.new
      settings[HT2::SettingsParameter::HEADER_TABLE_SIZE] = 8192_u32
      settings[HT2::SettingsParameter::MAX_CONCURRENT_STREAMS] = 50_u32

      connection.update_settings(settings)

      connection.local_settings[HT2::SettingsParameter::HEADER_TABLE_SIZE].should eq(8192_u32)
      connection.local_settings[HT2::SettingsParameter::MAX_CONCURRENT_STREAMS].should eq(50_u32)
    end

    it "updates encoder header table size" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, true)

      settings = HT2::SettingsFrame::Settings.new
      settings[HT2::SettingsParameter::HEADER_TABLE_SIZE] = 8192_u32

      connection.update_settings(settings)

      connection.hpack_encoder.max_dynamic_table_size.should eq(8192_u32)
    end

    it "updates decoder max header list size" do
      io = IO::Memory.new
      connection = HT2::Connection.new(io, true)

      settings = HT2::SettingsFrame::Settings.new
      settings[HT2::SettingsParameter::MAX_HEADER_LIST_SIZE] = 16_384_u32

      connection.update_settings(settings)

      connection.hpack_decoder.max_headers_size.should eq(16_384_u32)
    end
  end
end
