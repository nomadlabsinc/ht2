require "../spec_helper"

describe HT2::H2C do
  describe ".upgrade_request?" do
    it "returns true for valid h2c upgrade request" do
      headers = {
        "upgrade"        => "h2c",
        "connection"     => "Upgrade",
        "http2-settings" => "AAMAAABkAAQCAAAAAAIAAAAA",
      }
      HT2::H2C.upgrade_request?(headers).should be_true
    end

    it "returns false without upgrade header" do
      headers = {
        "connection"     => "Upgrade",
        "http2-settings" => "AAMAAABkAAQCAAAAAAIAAAAA",
      }
      HT2::H2C.upgrade_request?(headers).should be_false
    end

    it "returns false with wrong upgrade protocol" do
      headers = {
        "upgrade"        => "websocket",
        "connection"     => "Upgrade",
        "http2-settings" => "AAMAAABkAAQCAAAAAAIAAAAA",
      }
      HT2::H2C.upgrade_request?(headers).should be_false
    end

    it "returns false without connection upgrade" do
      headers = {
        "upgrade"        => "h2c",
        "connection"     => "close",
        "http2-settings" => "AAMAAABkAAQCAAAAAAIAAAAA",
      }
      HT2::H2C.upgrade_request?(headers).should be_false
    end

    it "returns false without http2-settings header" do
      headers = {
        "upgrade"    => "h2c",
        "connection" => "Upgrade",
      }
      HT2::H2C.upgrade_request?(headers).should be_false
    end
  end

  describe ".decode_settings" do
    it "decodes valid base64url encoded settings" do
      # Settings: HEADER_TABLE_SIZE=100, ENABLE_PUSH=0
      encoded = "AAEAAABkAAIAAAAA"
      settings = HT2::H2C.decode_settings(encoded)

      settings[HT2::SettingsParameter::HEADER_TABLE_SIZE]?.should eq(100_u32)
      settings[HT2::SettingsParameter::ENABLE_PUSH]?.should eq(0_u32)
    end

    it "handles empty settings" do
      encoded = ""
      settings = HT2::H2C.decode_settings(encoded)
      settings.should be_empty
    end

    it "returns empty settings for invalid base64" do
      encoded = "invalid base64!"
      settings = HT2::H2C.decode_settings(encoded)
      settings.should be_empty
    end
  end

  describe ".connection_preface?" do
    it "returns true for valid HTTP/2 preface" do
      data = HT2::CONNECTION_PREFACE.to_slice
      HT2::H2C.connection_preface?(data).should be_true
    end

    it "returns true when data contains preface at start" do
      data = Bytes.new(30)
      preface = HT2::CONNECTION_PREFACE.to_slice
      preface.copy_to(data)
      HT2::H2C.connection_preface?(data).should be_true
    end

    it "returns false for data shorter than preface" do
      data = Bytes.new(10)
      HT2::H2C.connection_preface?(data).should be_false
    end

    it "returns false for non-preface data" do
      data = "GET / HTTP/1.1\r\n".to_slice
      HT2::H2C.connection_preface?(data).should be_false
    end
  end

  describe ".read_http1_headers" do
    it "reads valid HTTP/1.1 request headers" do
      io = IO::Memory.new
      io << "GET /index.html HTTP/1.1\r\n"
      io << "Host: example.com\r\n"
      io << "Upgrade: h2c\r\n"
      io << "Connection: Upgrade\r\n"
      io << "HTTP2-Settings: AAMAAABkAAQCAAAAAAIAAAAA\r\n"
      io << "\r\n"
      io.rewind

      headers = HT2::H2C.read_http1_headers(io, 1.second)
      headers.should_not be_nil
      headers.not_nil!["_method"].should eq("GET")
      headers.not_nil!["_path"].should eq("/index.html")
      headers.not_nil!["host"].should eq("example.com")
      headers.not_nil!["upgrade"].should eq("h2c")
      headers.not_nil!["connection"].should eq("Upgrade")
      headers.not_nil!["http2-settings"].should eq("AAMAAABkAAQCAAAAAAIAAAAA")
    end

    it "returns nil for non-HTTP/1.1 request" do
      io = IO::Memory.new
      io << "GET / HTTP/1.0\r\n\r\n"
      io.rewind

      headers = HT2::H2C.read_http1_headers(io, 1.second)
      headers.should be_nil
    end

    it "returns nil on timeout" do
      # Create a blocking IO that will timeout
      reader, writer = IO.pipe

      headers = HT2::H2C.read_http1_headers(reader, 0.001.seconds)
      headers.should be_nil

      reader.close
      writer.close
    end

    it "handles headers with spaces" do
      io = IO::Memory.new
      io << "POST /api/test HTTP/1.1\r\n"
      io << "Host: example.com:8080\r\n"
      io << "Content-Type: application/json\r\n"
      io << "Content-Length: 123\r\n"
      io << "\r\n"
      io.rewind

      headers = HT2::H2C.read_http1_headers(io, 1.second)
      headers.should_not be_nil
      headers.not_nil!["content-type"].should eq("application/json")
      headers.not_nil!["content-length"].should eq("123")
    end
  end
end
