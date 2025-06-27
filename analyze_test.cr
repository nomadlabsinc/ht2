# Test what happens with multiple SETTINGS_INITIAL_WINDOW_SIZE values

require "./src/ht2"

# Simulate receiving SETTINGS with multiple INITIAL_WINDOW_SIZE values
settings = HT2::SettingsFrame.new
settings.settings[HT2::SettingsFrame::SettingsParameter::INITIAL_WINDOW_SIZE] = 0_u32

# Now let's see what happens when we parse a payload with duplicates
payload = Bytes.new(12)
# First setting: INITIAL_WINDOW_SIZE = 0
payload[0] = 0x00
payload[1] = 0x04  # INITIAL_WINDOW_SIZE
payload[2] = 0x00
payload[3] = 0x00
payload[4] = 0x00
payload[5] = 0x00

# Second setting: INITIAL_WINDOW_SIZE = 65536
payload[6] = 0x00
payload[7] = 0x04  # INITIAL_WINDOW_SIZE again
payload[8] = 0x00
payload[9] = 0x01
payload[10] = 0x00
payload[11] = 0x00

frame = HT2::SettingsFrame.parse_payload(payload)
puts "Settings: #{frame.settings}"
puts "Settings list: #{frame.settings_list}"

# The expectation is that both values should be processed in order
# First set window to 0, then to 65536
