require "./spec_helper"

describe HT2::HeaderValidator do
  describe "#validate" do
    it "accepts valid lowercase headers" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "GET"},
        {":scheme", "https"},
        {":path", "/"},
        {"content-type", "text/plain"},
        {"accept", "*/*"},
      ]

      validated = validator.validate(headers)
      validated.should eq(headers)
    end

    it "rejects uppercase header names" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "GET"},
        {":scheme", "https"},
        {":path", "/"},
        {"Content-Type", "text/plain"},
      ]

      expect_raises(HT2::StreamError, /must be lowercase/) do
        validator.validate(headers)
      end
    end

    it "rejects unknown pseudo-headers" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "GET"},
        {":scheme", "https"},
        {":path", "/"},
        {":unknown", "value"},
      ]

      expect_raises(HT2::StreamError, /Unknown pseudo-header/) do
        validator.validate(headers)
      end
    end

    it "rejects response pseudo-headers in requests" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "GET"},
        {":scheme", "https"},
        {":path", "/"},
        {":status", "200"},
      ]

      expect_raises(HT2::StreamError, /Response pseudo-header in request/) do
        validator.validate(headers)
      end
    end

    it "rejects pseudo-headers after regular headers" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "GET"},
        {"content-type", "text/plain"},
        {":scheme", "https"},
        {":path", "/"},
      ]

      expect_raises(HT2::StreamError, /Pseudo-header field after regular header/) do
        validator.validate(headers)
      end
    end

    it "rejects duplicate pseudo-headers" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "GET"},
        {":method", "POST"},
        {":scheme", "https"},
        {":path", "/"},
      ]

      expect_raises(HT2::StreamError, /Duplicate pseudo-header/) do
        validator.validate(headers)
      end
    end

    it "rejects empty :path pseudo-header" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "GET"},
        {":scheme", "https"},
        {":path", ""},
      ]

      expect_raises(HT2::StreamError, /Empty :path/) do
        validator.validate(headers)
      end
    end

    it "rejects missing required pseudo-headers" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "GET"},
        {":scheme", "https"}, # Missing :path
      ]

      expect_raises(HT2::StreamError, /Missing required pseudo-header: :path/) do
        validator.validate(headers)
      end
    end

    it "strips connection-specific headers" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "GET"},
        {":scheme", "https"},
        {":path", "/"},
        {"connection", "keep-alive"},
        {"keep-alive", "timeout=5"},
        {"content-type", "text/plain"},
      ]

      validated = validator.validate(headers)
      validated.should eq([
        {":method", "GET"},
        {":scheme", "https"},
        {":path", "/"},
        {"content-type", "text/plain"},
      ])
    end

    it "rejects TE header with value other than trailers" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "GET"},
        {":scheme", "https"},
        {":path", "/"},
        {"te", "gzip"},
      ]

      expect_raises(HT2::StreamError, /TE header field with value other than/) do
        validator.validate(headers)
      end
    end

    it "accepts TE header with trailers value" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "POST"},
        {":scheme", "https"},
        {":path", "/"},
        {"te", "trailers"},
      ]

      validated = validator.validate(headers)
      validated.should eq(headers)
    end

    it "validates content-length header" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "POST"},
        {":scheme", "https"},
        {":path", "/"},
        {"content-length", "invalid"},
      ]

      expect_raises(HT2::StreamError, /Invalid content-length/) do
        validator.validate(headers)
      end
    end

    it "rejects multiple content-length headers with different values" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "POST"},
        {":scheme", "https"},
        {":path", "/"},
        {"content-length", "100"},
        {"content-length", "200"},
      ]

      expect_raises(HT2::StreamError, /Multiple content-length headers/) do
        validator.validate(headers)
      end
    end

    it "accepts multiple content-length headers with same value" do
      validator = HT2::HeaderValidator.new(is_request: true)
      headers = [
        {":method", "POST"},
        {":scheme", "https"},
        {":path", "/"},
        {"content-length", "100"},
        {"content-length", "100"},
      ]

      validated = validator.validate(headers)
      validated.size.should eq(5)
    end
  end

  describe ".get_content_length" do
    it "returns content-length value if present" do
      headers = [
        {":method", "POST"},
        {"content-length", "1234"},
      ]

      HT2::HeaderValidator.get_content_length(headers).should eq(1234_u64)
    end

    it "returns nil if no content-length" do
      headers = [
        {":method", "GET"},
      ]

      HT2::HeaderValidator.get_content_length(headers).should be_nil
    end

    it "returns nil for invalid content-length" do
      headers = [
        {":method", "POST"},
        {"content-length", "invalid"},
      ]

      HT2::HeaderValidator.get_content_length(headers).should be_nil
    end
  end

  describe ".has_trailers?" do
    it "detects trailers" do
      headers = [
        {":method", "POST"},
        {"te", "trailers"},
      ]

      HT2::HeaderValidator.has_trailers?(headers).should be_true
    end

    it "returns false when no trailers" do
      headers = [
        {":method", "POST"},
      ]

      HT2::HeaderValidator.has_trailers?(headers).should be_false
    end
  end
end
