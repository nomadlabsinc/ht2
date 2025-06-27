module HT2
  class SettingsFrame < Frame
    alias Settings = Hash(SettingsParameter, UInt32)
    alias SettingsPair = Tuple(SettingsParameter, UInt32)
    alias SettingsList = Array(SettingsPair)

    getter settings : Settings
    getter settings_list : SettingsList

    def initialize(@flags : FrameFlags = FrameFlags::None, @settings : Settings = Settings.new, settings_list : SettingsList? = nil)
      super(0_u32, @flags) # SETTINGS always on stream 0
      # If settings_list wasn't provided, build it from settings hash
      @settings_list = settings_list || @settings.map { |k, v| {k, v} }
    end

    def frame_type : FrameType
      FrameType::SETTINGS
    end

    def payload : Bytes
      bytes = Bytes.new(@settings_list.size * 6)
      offset = 0

      @settings_list.each do |param, value|
        # Parameter ID (16 bits)
        bytes[offset] = ((param.value >> 8) & 0xFF).to_u8
        bytes[offset + 1] = (param.value & 0xFF).to_u8

        # Value (32 bits)
        bytes[offset + 2] = ((value >> 24) & 0xFF).to_u8
        bytes[offset + 3] = ((value >> 16) & 0xFF).to_u8
        bytes[offset + 4] = ((value >> 8) & 0xFF).to_u8
        bytes[offset + 5] = (value & 0xFF).to_u8

        offset += 6
      end

      bytes
    end

    def self.parse_payload(stream_id : UInt32, flags : FrameFlags, payload : Bytes) : SettingsFrame
      if stream_id != 0
        raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "SETTINGS frame with non-zero stream ID")
      end

      if flags.ack? && payload.size > 0
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "SETTINGS ACK with non-empty payload")
      end

      if payload.size % 6 != 0
        raise ConnectionError.new(ErrorCode::FRAME_SIZE_ERROR, "SETTINGS payload size not multiple of 6")
      end

      settings = Settings.new
      settings_list = SettingsList.new

      (0...payload.size).step(6) do |i|
        param_id = (payload[i].to_u16 << 8) | payload[i + 1].to_u16
        value = (payload[i + 2].to_u32 << 24) |
                (payload[i + 3].to_u32 << 16) |
                (payload[i + 4].to_u32 << 8) |
                payload[i + 5].to_u32

        begin
          param = SettingsParameter.new(param_id)

          # Validate settings values
          case param
          when SettingsParameter::ENABLE_PUSH
            if value > 1
              raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "ENABLE_PUSH must be 0 or 1")
            end
          when SettingsParameter::INITIAL_WINDOW_SIZE
            if value > 0x7FFFFFFF
              raise ConnectionError.new(ErrorCode::FLOW_CONTROL_ERROR, "INITIAL_WINDOW_SIZE too large")
            end
          when SettingsParameter::MAX_FRAME_SIZE
            if value < 16_384 || value > 16_777_215
              raise ConnectionError.new(ErrorCode::PROTOCOL_ERROR, "MAX_FRAME_SIZE out of range")
            end
          end

          # Add to list to preserve order and allow duplicates
          settings_list << {param, value}
          # Update hash with latest value
          settings[param] = value
        rescue ArgumentError
          # Unknown setting - ignore as per spec
        end
      end

      SettingsFrame.new(flags, settings, settings_list)
    end

    def self.default_settings : SettingsFrame
      settings = Settings.new
      settings[SettingsParameter::HEADER_TABLE_SIZE] = DEFAULT_HEADER_TABLE_SIZE
      settings[SettingsParameter::ENABLE_PUSH] = 1_u32
      settings[SettingsParameter::MAX_CONCURRENT_STREAMS] = DEFAULT_MAX_CONCURRENT_STREAMS
      settings[SettingsParameter::INITIAL_WINDOW_SIZE] = DEFAULT_INITIAL_WINDOW_SIZE
      settings[SettingsParameter::MAX_FRAME_SIZE] = DEFAULT_MAX_FRAME_SIZE
      settings[SettingsParameter::MAX_HEADER_LIST_SIZE] = DEFAULT_MAX_HEADER_LIST_SIZE

      SettingsFrame.new(settings: settings)
    end
  end
end
