require "./spec_helper"

describe HT2::RapidResetProtection do
  describe "initialization" do
    it "creates with default config" do
      protection = HT2::RapidResetProtection.new

      protection.config.max_streams_per_second.should eq(100)
      protection.config.max_rapid_resets_per_minute.should eq(50)
      protection.config.rapid_reset_threshold_ms.should eq(100.0)
      protection.config.pending_stream_limit.should eq(1000)
    end

    it "accepts custom config" do
      config = HT2::RapidResetProtection::Config.new(
        max_streams_per_second: 50,
        max_rapid_resets_per_minute: 25,
        rapid_reset_threshold_ms: 50.0,
        pending_stream_limit: 500
      )
      protection = HT2::RapidResetProtection.new(config)

      protection.config.max_streams_per_second.should eq(50)
    end
  end

  describe "stream creation limits" do
    it "allows normal stream creation" do
      protection = HT2::RapidResetProtection.new
      connection_id = "test-connection"

      # Should allow creating streams under the limit
      10.times do |i|
        protection.record_stream_created(i.to_u32 * 2 + 1, connection_id).should be_true
      end
    end

    it "enforces stream creation rate limit" do
      config = HT2::RapidResetProtection::Config.new(max_streams_per_second: 5)
      protection = HT2::RapidResetProtection.new(config)
      connection_id = "test-connection"

      # Create 5 streams (at the limit)
      5.times do |i|
        protection.record_stream_created(i.to_u32 * 2 + 1, connection_id).should be_true
      end

      # 6th stream should fail
      protection.record_stream_created(11_u32, connection_id).should be_false
      protection.banned?(connection_id).should be_true
    end

    it "enforces pending stream limit" do
      config = HT2::RapidResetProtection::Config.new(pending_stream_limit: 5)
      protection = HT2::RapidResetProtection.new(config)
      connection_id = "test-connection"

      # Create 5 pending streams
      5.times do |i|
        protection.record_stream_created(i.to_u32 * 2 + 1, connection_id).should be_true
      end

      # 6th stream should fail due to pending limit
      protection.record_stream_created(11_u32, connection_id).should be_false
      protection.banned?(connection_id).should be_true
    end

    it "removes streams from pending when headers received" do
      protection = HT2::RapidResetProtection.new
      connection_id = "test-connection"

      protection.record_stream_created(1_u32, connection_id).should be_true
      protection.record_headers_received(1_u32)

      metrics = protection.metrics
      metrics[:pending_streams].should eq(0)
    end
  end

  describe "rapid reset detection" do
    it "detects rapid cancellations" do
      config = HT2::RapidResetProtection::Config.new(
        max_rapid_resets_per_minute: 3,
        rapid_reset_threshold_ms: 100.0
      )
      protection = HT2::RapidResetProtection.new(config)
      connection_id = "test-connection"

      # Create and immediately cancel streams
      3.times do |i|
        stream_id = (i * 2 + 1).to_u32
        protection.record_stream_created(stream_id, connection_id).should be_true
        protection.record_stream_cancelled(stream_id, connection_id).should be_true
      end

      # 4th rapid reset should trigger ban
      protection.record_stream_created(7_u32, connection_id).should be_true
      protection.record_stream_cancelled(7_u32, connection_id).should be_false
      protection.banned?(connection_id).should be_true
    end

    it "does not count normal stream closures as rapid resets" do
      config = HT2::RapidResetProtection::Config.new(max_rapid_resets_per_minute: 2)
      protection = HT2::RapidResetProtection.new(config)
      connection_id = "test-connection"

      # Create stream, receive data, then cancel - should not count as rapid
      protection.record_stream_created(1_u32, connection_id).should be_true
      protection.record_headers_received(1_u32)
      protection.record_data_received(1_u32)
      sleep 150.milliseconds # Wait past rapid threshold
      protection.record_stream_cancelled(1_u32, connection_id).should be_true

      # Should not be banned
      protection.banned?(connection_id).should be_false
    end

    it "counts cancellations without data as rapid" do
      protection = HT2::RapidResetProtection.new
      connection_id = "test-connection"

      # Create stream, receive headers but no data, cancel quickly
      protection.record_stream_created(1_u32, connection_id).should be_true
      protection.record_headers_received(1_u32)
      protection.record_stream_cancelled(1_u32, connection_id).should be_true

      # Check metrics show rapid reset
      metrics = protection.metrics
      metrics[:rapid_reset_counts][connection_id]?.should eq(1)
    end
  end

  describe "ban management" do
    it "bans connections that exceed limits" do
      config = HT2::RapidResetProtection::Config.new(
        max_streams_per_second: 5,
        ban_duration: 100.milliseconds
      )
      protection = HT2::RapidResetProtection.new(config)
      connection_id = "test-connection"

      # Exceed rate limit to get banned
      6.times do |i|
        protection.record_stream_created(i.to_u32 * 2 + 1, connection_id)
      end

      protection.banned?(connection_id).should be_true

      # Wait for ban to expire
      sleep 150.milliseconds
      protection.banned?(connection_id).should be_false
    end

    it "prevents all operations while banned" do
      config = HT2::RapidResetProtection::Config.new(max_streams_per_second: 1)
      protection = HT2::RapidResetProtection.new(config)
      connection_id = "test-connection"

      # Get banned
      protection.record_stream_created(1_u32, connection_id).should be_true
      protection.record_stream_created(3_u32, connection_id).should be_false

      # All operations should fail while banned
      protection.record_stream_created(5_u32, connection_id).should be_false
      protection.record_stream_cancelled(1_u32, connection_id).should be_false
    end
  end

  describe "metrics" do
    it "provides accurate metrics" do
      protection = HT2::RapidResetProtection.new
      connection_id = "test-connection"

      # Create some streams
      protection.record_stream_created(1_u32, connection_id)
      protection.record_stream_created(3_u32, connection_id)
      protection.record_headers_received(1_u32)

      metrics = protection.metrics
      metrics[:active_streams].should eq(2)
      metrics[:pending_streams].should eq(1) # Stream 3 is still pending
      metrics[:banned_connections].should eq(0)
    end

    it "tracks rapid reset counts per connection" do
      protection = HT2::RapidResetProtection.new
      conn1 = "connection-1"
      conn2 = "connection-2"

      # Rapid resets on different connections
      protection.record_stream_created(1_u32, conn1)
      protection.record_stream_cancelled(1_u32, conn1)

      protection.record_stream_created(3_u32, conn2)
      protection.record_stream_cancelled(3_u32, conn2)

      metrics = protection.metrics
      metrics[:rapid_reset_counts][conn1]?.should eq(1)
      metrics[:rapid_reset_counts][conn2]?.should eq(1)
    end
  end

  describe "cleanup" do
    it "removes closed streams from tracking" do
      protection = HT2::RapidResetProtection.new
      connection_id = "test-connection"

      protection.record_stream_created(1_u32, connection_id)
      protection.record_stream_closed(1_u32)

      metrics = protection.metrics
      metrics[:active_streams].should eq(0)
      metrics[:pending_streams].should eq(0)
    end
  end
end
