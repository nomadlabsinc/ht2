module HT2
  # Cache for frequently used frame payloads
  class FrameCache
    @cache : Hash(String, Bytes)
    @mutex : Mutex

    def initialize
      @cache = Hash(String, Bytes).new
      @mutex = Mutex.new

      # Pre-cache common frames
      cache_common_frames
    end

    # Get cached frame bytes or compute and cache
    def get_or_set(key : String, & : -> Bytes) : Bytes
      @mutex.synchronize do
        if cached = @cache[key]?
          return cached.dup
        end

        bytes = yield
        @cache[key] = bytes.dup
        bytes
      end
    end

    # Get cached frame bytes
    def get(key : String) : Bytes?
      @mutex.synchronize do
        @cache[key]?.try(&.dup)
      end
    end

    # Clear the cache
    def clear : Nil
      @mutex.synchronize do
        @cache.clear
      end
    end

    private def cache_common_frames
      # Cache SETTINGS ACK frame
      settings_ack = SettingsFrame.new(flags: FrameFlags::ACK)
      @cache["settings_ack"] = settings_ack.to_bytes

      # Cache common PING frames
      ping_ack_data = Bytes.new(8, 0)
      ping_ack = PingFrame.new(ping_ack_data, FrameFlags::ACK)
      @cache["ping_ack_0"] = ping_ack.to_bytes
    end
  end
end
