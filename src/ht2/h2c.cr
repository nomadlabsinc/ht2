require "base64"
require "./buffered_socket"
require "./frames"

module HT2
  module H2C
    # HTTP/1.1 headers required for h2c upgrade
    UPGRADE_HEADER        = "Upgrade"
    CONNECTION_HEADER     = "Connection"
    HTTP2_SETTINGS_HEADER = "HTTP2-Settings"

    # Values for upgrade headers
    H2C_PROTOCOL       = "h2c"
    UPGRADE_CONNECTION = "Upgrade"

    # HTTP/1.1 response for successful upgrade
    SWITCHING_PROTOCOLS_RESPONSE = "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n"

    # Common HTTP/1.1 method names for detection
    HTTP1_METHODS = ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH", "CONNECT", "TRACE"]

    # Checks if an HTTP/1.1 request is an h2c upgrade request
    def self.upgrade_request?(headers : Hash(String, String)) : Bool
      return false unless headers[UPGRADE_HEADER.downcase]? == H2C_PROTOCOL
      return false unless headers[CONNECTION_HEADER.downcase]?.try(&.includes?(UPGRADE_CONNECTION))
      return false unless headers.has_key?(HTTP2_SETTINGS_HEADER.downcase)
      true
    end

    # Decodes HTTP2-Settings header value (base64url encoded SETTINGS frame)
    def self.decode_settings(encoded : String) : SettingsFrame::Settings
      # Decode base64url (no padding, - and _ instead of + and /)
      decoded = Base64.decode_string(encoded.tr("-_", "+/"))
      io = IO::Memory.new(decoded)

      settings = SettingsFrame::Settings.new

      # Parse settings parameters
      while io.pos < io.size
        # Read parameter ID (16 bits)
        param_bytes = Bytes.new(2)
        io.read_fully(param_bytes)
        param_id = (param_bytes[0].to_u16 << 8) | param_bytes[1]

        # Read parameter value (32 bits)
        value_bytes = Bytes.new(4)
        io.read_fully(value_bytes)
        value = (value_bytes[0].to_u32 << 24) | (value_bytes[1].to_u32 << 16) |
                (value_bytes[2].to_u32 << 8) | value_bytes[3]

        # Apply setting if valid
        if param = SettingsParameter.from_value?(param_id)
          settings[param] = value
        end
      end

      settings
    rescue
      # Return empty settings on decode error
      SettingsFrame::Settings.new
    end

    # Checks if bytes represent HTTP/2 connection preface
    def self.connection_preface?(data : Bytes) : Bool
      return false if data.size < CONNECTION_PREFACE.bytesize

      preface_bytes = CONNECTION_PREFACE.to_slice
      data[0, preface_bytes.size] == preface_bytes
    end

    # Detects if the initial bytes are HTTP/2 prior knowledge connection
    def self.h2_prior_knowledge?(data : Bytes) : Bool
      return false if data.size < CONNECTION_PREFACE.bytesize
      data[0, CONNECTION_PREFACE.bytesize] == CONNECTION_PREFACE.to_slice
    end

    # Detects if the initial bytes are HTTP/1.1
    def self.http1_request?(data : Bytes) : Bool
      return false if data.size < 3

      # Check if it starts with a known HTTP method
      data_str = String.new(data[0, Math.min(data.size, 16)])
      HTTP1_METHODS.any? { |method| data_str.starts_with?(method) }
    end

    # Detects connection type from initial bytes
    enum ConnectionType
      Unknown
      H2PriorKnowledge
      Http1
    end

    def self.detect_connection_type(data : Bytes) : ConnectionType
      return ConnectionType::Unknown if data.size < 3

      if h2_prior_knowledge?(data)
        ConnectionType::H2PriorKnowledge
      elsif http1_request?(data)
        ConnectionType::Http1
      else
        ConnectionType::Unknown
      end
    end

    # Reads HTTP/1.1 request headers from socket
    def self.read_http1_headers(socket : IO, timeout : Time::Span) : Hash(String, String)?
      headers = Hash(String, String).new
      # buffer = IO::Memory.new # Not used

      # Set read timeout
      if socket.responds_to?(:read_timeout=)
        socket.read_timeout = timeout
      end

      # Read request line
      line = socket.gets(limit: 8192)
      return nil unless line

      # Strip the \r\n
      line = line.chomp

      # Parse request line
      parts = line.strip.split(' ')
      return nil unless parts.size == 3

      method, path, version = parts
      return nil unless version == "HTTP/1.1"

      headers["_method"] = method
      headers["_path"] = path

      # Read headers
      while line = socket.gets(limit: 8192)
        break if line == "\r\n" || line.strip.empty?

        line = line.chomp

        colon_index = line.index(':')
        next unless colon_index

        key = line[0...colon_index].strip.downcase
        value = line[colon_index + 1..-1].strip

        headers[key] = value
      end

      headers
    rescue IO::TimeoutError
      nil
    ensure
      # Reset timeout
      if socket.responds_to?(:read_timeout=)
        socket.read_timeout = nil
      end
    end
  end
end
