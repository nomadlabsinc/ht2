require "log"

module HT2
  # Debug mode configuration and frame logging support
  class DebugMode
    # Logger instance for HT2 debug output
    Log = ::Log.for("ht2.debug")

    # Frame direction for logging
    enum Direction
      Inbound
      Outbound
    end

    # Configuration for debug mode
    struct Config
      property? frame_logging : Bool
      property frame_data_limit : Int32
      property log_level : ::Log::Severity

      def initialize(
        @frame_logging : Bool = true,
        @frame_data_limit : Int32 = 256,
        @log_level : ::Log::Severity = ::Log::Severity::Debug,
      )
      end
    end

    @@enabled : Bool = false
    @@config : Config = Config.new

    # Enable debug mode with optional configuration
    def self.enable(config : Config? = nil) : Nil
      @@enabled = true
      @@config = config || Config.new
      setup_logger unless ENV["CRYSTAL_SPEC"]?
    end

    # Disable debug mode
    def self.disable : Nil
      @@enabled = false
    end

    # Check if debug mode is enabled
    def self.enabled? : Bool
      @@enabled
    end

    # Get current configuration
    def self.config : Config
      @@config
    end

    # Log a frame with direction and connection info
    def self.log_frame(
      connection_id : String,
      direction : Direction,
      frame : Frame,
      stream_id : UInt32? = nil,
    ) : Nil
      return unless @@enabled && @@config.frame_logging?

      # Frame logging disabled
    end

    # Log raw frame bytes
    def self.log_raw_frame(
      connection_id : String,
      direction : Direction,
      bytes : Bytes,
    ) : Nil
      return unless @@enabled && @@config.frame_logging?

      Log.trace do
        String.build do |str|
          str << "[#{connection_id}] "
          str << "#{direction} RAW "
          str << "#{bytes.size} bytes: "
          str << format_bytes(bytes)
        end
      end
    end

    private def self.setup_logger : Nil
      backend = ::Log::IOBackend.new
      backend.formatter = ::Log::Formatter.new do |entry, io|
        io << entry.timestamp.to_s("%Y-%m-%d %H:%M:%S.%3N")
        io << " [#{entry.severity.label}]"
        io << " #{entry.source}: " if entry.source != ""
        io << entry.message
        if ex = entry.exception
          io << " - " << ex.class << ": " << ex.message
          ex.backtrace?.try &.each do |line|
            io << "\n  " << line
          end
        end
      end

      ::Log.builder.bind "ht2.*", @@config.log_level, backend
    end

    private def self.format_frame_details(frame : Frame) : String
      String.build do |str|
        case frame
        when DataFrame
          str << "flags=#{format_flags(frame)} "
          str << "length=#{frame.data.size}"
          if @@config.frame_data_limit > 0 && frame.data.size > 0
            data_preview = frame.data[0, Math.min(frame.data.size, @@config.frame_data_limit)]
            str << " data=" << data_preview.inspect
            str << "..." if frame.data.size > @@config.frame_data_limit
          end
        when HeadersFrame
          str << "flags=#{format_flags(frame)} "
          str << "priority=#{frame.priority} " if frame.priority
          str << "block_size=#{frame.header_block.size}"
        when PriorityFrame
          str << "exclusive=#{frame.priority.exclusive?} "
          str << "dependency=#{frame.priority.stream_dependency} "
          str << "weight=#{frame.priority.weight}"
        when RstStreamFrame
          str << "error=#{frame.error_code}"
        when SettingsFrame
          str << "flags=#{format_flags(frame)} "
          if frame.flags.ack?
            str << "ACK"
          else
            str << "params={"
            frame.settings.each_with_index do |(k, v), i|
              str << ", " if i > 0
              str << "#{k}=#{v}"
            end
            str << "}"
          end
        when PushPromiseFrame
          str << "flags=#{format_flags(frame)} "
          str << "promised=#{frame.promised_stream_id} "
          str << "block_size=#{frame.header_block.size}"
        when PingFrame
          str << "flags=#{format_flags(frame)} "
          str << "data=#{frame.opaque_data.hexstring}"
        when GoAwayFrame
          str << "last_stream=#{frame.last_stream_id} "
          str << "error=#{frame.error_code} "
          str << "debug_data=#{frame.debug_data.inspect}" if frame.debug_data.size > 0
        when WindowUpdateFrame
          str << "increment=#{frame.window_size_increment}"
        when ContinuationFrame
          str << "flags=#{format_flags(frame)} "
          str << "block_size=#{frame.header_block.size}"
        end
      end
    end

    private def self.format_flags(frame : Frame) : String
      flags = [] of String

      case frame
      when DataFrame
        flags << "END_STREAM" if frame.flags.end_stream?
        flags << "PADDED" if frame.flags.padded?
      when HeadersFrame
        flags << "END_STREAM" if frame.flags.end_stream?
        flags << "END_HEADERS" if frame.flags.end_headers?
        flags << "PADDED" if frame.flags.padded?
        flags << "PRIORITY" if frame.flags.priority?
      when SettingsFrame
        flags << "ACK" if frame.flags.ack?
      when PingFrame
        flags << "ACK" if frame.flags.ack?
      when PushPromiseFrame
        flags << "END_HEADERS" if frame.flags.end_headers?
        flags << "PADDED" if frame.flags.padded?
      when ContinuationFrame
        flags << "END_HEADERS" if frame.flags.end_headers?
      end

      flags.empty? ? "NONE" : flags.join("|")
    end

    private def self.format_bytes(bytes : Bytes) : String
      if bytes.size <= 32
        bytes.hexstring
      else
        "#{bytes[0, 32].hexstring}... (#{bytes.size - 32} more bytes)"
      end
    end
  end
end
