require "../spec_helper"

describe "HT2::Client Connection Pooling" do
  describe "connection reuse" do
    pending "reuses the same connection for multiple requests"
  end

  describe "connection limits" do
    pending "respects max connections per host"
  end

  describe "connection health" do
    pending "removes unhealthy connections"
  end

  describe "#warm_up" do
    pending "pre-establishes connections"
  end

  describe "#drain_connections" do
    pending "gracefully closes connections"
  end
end
