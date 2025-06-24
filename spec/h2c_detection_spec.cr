require "./spec_helper"

describe HT2::H2C do
  describe ".detect_connection_type" do
    it "detects HTTP/2 prior knowledge connection" do
      preface_bytes = HT2::CONNECTION_PREFACE.to_slice
      HT2::H2C.detect_connection_type(preface_bytes).should eq HT2::H2C::ConnectionType::H2PriorKnowledge
    end

    it "detects HTTP/1.1 GET request" do
      request = "GET / HTTP/1.1\r\n".to_slice
      HT2::H2C.detect_connection_type(request).should eq HT2::H2C::ConnectionType::Http1
    end

    it "detects HTTP/1.1 POST request" do
      request = "POST /api HTTP/1.1\r\n".to_slice
      HT2::H2C.detect_connection_type(request).should eq HT2::H2C::ConnectionType::Http1
    end

    it "detects HTTP/1.1 PUT request" do
      request = "PUT /resource HTTP/1.1\r\n".to_slice
      HT2::H2C.detect_connection_type(request).should eq HT2::H2C::ConnectionType::Http1
    end

    it "returns Unknown for insufficient data" do
      data = "GE".to_slice
      HT2::H2C.detect_connection_type(data).should eq HT2::H2C::ConnectionType::Unknown
    end

    it "returns Unknown for non-HTTP data" do
      data = "INVALID DATA HERE".to_slice
      HT2::H2C.detect_connection_type(data).should eq HT2::H2C::ConnectionType::Unknown
    end
  end

  describe ".h2_prior_knowledge?" do
    it "returns true for valid H2 preface" do
      preface = HT2::CONNECTION_PREFACE.to_slice
      HT2::H2C.h2_prior_knowledge?(preface).should be_true
    end

    it "returns false for partial preface" do
      partial = "PRI * HTTP/2.0".to_slice
      HT2::H2C.h2_prior_knowledge?(partial).should be_false
    end

    it "returns false for invalid data" do
      data = "GET / HTTP/1.1\r\n".to_slice
      HT2::H2C.h2_prior_knowledge?(data).should be_false
    end
  end

  describe ".http1_request?" do
    HT2::H2C::HTTP1_METHODS.each do |method|
      it "detects #{method} request" do
        request = "#{method} / HTTP/1.1\r\n".to_slice
        HT2::H2C.http1_request?(request).should be_true
      end
    end

    it "returns false for non-HTTP data" do
      data = "INVALID".to_slice
      HT2::H2C.http1_request?(data).should be_false
    end

    it "returns false for H2 preface" do
      preface = HT2::CONNECTION_PREFACE.to_slice
      HT2::H2C.http1_request?(preface).should be_false
    end
  end
end
