require "./spec_helper"

describe HT2::AdaptiveFlowControl do
  describe "initialization" do
    it "sets initial values correctly" do
      flow_controller = HT2::AdaptiveFlowControl.new(65535_i64)

      flow_controller.initial_window_size.should eq(65535)
      flow_controller.strategy.should eq(HT2::AdaptiveFlowControl::Strategy::MODERATE)
      flow_controller.current_threshold.should eq(0.5)
    end

    it "sets threshold based on strategy" do
      conservative = HT2::AdaptiveFlowControl.new(65535_i64, HT2::AdaptiveFlowControl::Strategy::CONSERVATIVE)
      conservative.current_threshold.should eq(0.25)

      aggressive = HT2::AdaptiveFlowControl.new(65535_i64, HT2::AdaptiveFlowControl::Strategy::AGGRESSIVE)
      aggressive.current_threshold.should eq(0.75)

      dynamic = HT2::AdaptiveFlowControl.new(65535_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)
      dynamic.current_threshold.should eq(0.5) # Starts moderate
    end
  end

  describe "needs_update?" do
    it "returns true when window falls below threshold" do
      flow_controller = HT2::AdaptiveFlowControl.new(65535_i64, HT2::AdaptiveFlowControl::Strategy::MODERATE)

      # Window at 40% (below 50% threshold)
      flow_controller.needs_update?(65535_i64, 26214_i64).should be_true

      # Window at 60% (above 50% threshold)
      flow_controller.needs_update?(65535_i64, 39321_i64).should be_false
    end

    it "returns false when current window is zero or negative" do
      flow_controller = HT2::AdaptiveFlowControl.new(65535_i64)

      flow_controller.needs_update?(0_i64, 0_i64).should be_false
      flow_controller.needs_update?(-100_i64, 0_i64).should be_false
    end
  end

  describe "calculate_increment" do
    it "calculates increment based on strategy" do
      initial_window = 65535_i64

      conservative = HT2::AdaptiveFlowControl.new(initial_window, HT2::AdaptiveFlowControl::Strategy::CONSERVATIVE)
      moderate = HT2::AdaptiveFlowControl.new(initial_window, HT2::AdaptiveFlowControl::Strategy::MODERATE)
      aggressive = HT2::AdaptiveFlowControl.new(initial_window, HT2::AdaptiveFlowControl::Strategy::AGGRESSIVE)

      # Conservative gives smallest increment
      conservative_inc = conservative.calculate_increment(32768_i64, 16384_i64)
      conservative_inc.should be <= initial_window / 4

      # Moderate gives half window
      moderate_inc = moderate.calculate_increment(32768_i64, 16384_i64)
      moderate_inc.should eq((initial_window / 2).to_i32)

      # Aggressive gives full window
      aggressive_inc = aggressive.calculate_increment(32768_i64, 16384_i64)
      aggressive_inc.should eq(initial_window.to_i32)
    end

    it "respects maximum window size limit" do
      flow_controller = HT2::AdaptiveFlowControl.new(65535_i64, HT2::AdaptiveFlowControl::Strategy::AGGRESSIVE)

      # Current window very close to max
      current_window = HT2::Security::MAX_WINDOW_SIZE - 1000
      increment = flow_controller.calculate_increment(current_window, 1000_i64)

      increment.should eq(1000) # Should only increment up to max
    end
  end

  describe "dynamic strategy" do
    it "adapts threshold based on consumption rate" do
      flow_controller = HT2::AdaptiveFlowControl.new(65535_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)
      initial_threshold = flow_controller.current_threshold

      # Simulate high consumption to trigger dynamic threshold update
      # First establish a baseline consumption rate
      flow_controller.calculate_increment(32768_i64, 32768_i64)
      sleep 10.milliseconds

      # Now simulate sustained high consumption
      5.times do
        flow_controller.calculate_increment(10000_i64, 55535_i64)
        flow_controller.needs_update?(65535_i64, 10000_i64) # This will trigger threshold update
        sleep 10.milliseconds
      end

      # Threshold should increase (update earlier) for high consumption
      flow_controller.current_threshold.should be > initial_threshold
    end

    it "adjusts increment based on consumption patterns" do
      flow_controller = HT2::AdaptiveFlowControl.new(65535_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)

      # Simulate very high consumption rate
      5.times do
        flow_controller.calculate_increment(10000_i64, 55535_i64)
        sleep 10.milliseconds # Small delay to establish rate
      end

      # Should give larger increment for high consumption
      high_inc = flow_controller.calculate_increment(10000_i64, 55535_i64)
      high_inc.should be >= 49151 # At least 75% of window
    end
  end

  describe "stall tracking" do
    it "records stalls and adapts strategy" do
      flow_controller = HT2::AdaptiveFlowControl.new(65535_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)
      initial_threshold = flow_controller.current_threshold

      # Record multiple stalls
      3.times { flow_controller.record_stall }

      # Adapt strategy based on stalls
      flow_controller.adapt_strategy

      # Should become more aggressive after stalls
      flow_controller.current_threshold.should be > initial_threshold
      flow_controller.metrics.stall_count.should eq(0) # Reset after adaptation
    end
  end

  describe "network adaptation" do
    it "becomes more conservative with high RTT" do
      flow_controller = HT2::AdaptiveFlowControl.new(65535_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)
      initial_threshold = flow_controller.current_threshold

      # High RTT should make it more conservative
      flow_controller.adapt_strategy(rtt_ms: 150.0)
      flow_controller.current_threshold.should be < initial_threshold
    end

    it "becomes more conservative with packet loss" do
      flow_controller = HT2::AdaptiveFlowControl.new(65535_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)
      initial_threshold = flow_controller.current_threshold

      # Packet loss should make it more conservative
      flow_controller.adapt_strategy(loss_rate: 0.05)
      flow_controller.current_threshold.should be < initial_threshold
    end
  end

  describe "enhanced dynamic window update strategy" do
    it "tracks burst detection state" do
      flow_control = HT2::AdaptiveFlowControl.new(65536_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)

      # Initially no burst
      flow_control.metrics.burst_detected?.should be_false

      # Can manually set burst state for testing
      flow_control.metrics.burst_detected = true
      flow_control.metrics.burst_detected?.should be_true

      # Calculate increment during burst should give aggressive allocation
      increment = flow_control.calculate_increment(10000_i64, 50000_i64)
      increment.should be >= 65536 # At least full window during burst
    end

    it "adapts threshold based on consumption variance" do
      flow_control = HT2::AdaptiveFlowControl.new(65536_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)
      initial_threshold = flow_control.current_threshold

      # Simulate variable consumption with needs_update checks
      consumptions = [5000_i64, 50000_i64, 10000_i64, 45000_i64, 8000_i64]

      consumptions.each_with_index do |consumed, i|
        window = 65536_i64 - (consumed * (i + 1))
        # This triggers threshold updates
        flow_control.needs_update?(65536_i64, window)
        flow_control.calculate_increment(window, consumed)
        sleep 50.milliseconds
      end

      # Threshold should have adapted due to high variance
      flow_control.current_threshold.should_not eq(initial_threshold)
      flow_control.metrics.rate_variance.should be > 0
    end

    it "prevents stalls by increasing allocation after stall events" do
      flow_control = HT2::AdaptiveFlowControl.new(65536_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)

      # Record a stall
      flow_control.record_stall
      flow_control.metrics.stall_count.should eq(1)

      # Calculate increment after stall
      increment = flow_control.calculate_increment(1000_i64, 64536_i64)

      # Should allocate aggressively to prevent future stalls
      increment.should be >= 65536 # At least full window
    end

    it "uses predictive allocation for stable consumption" do
      flow_control = HT2::AdaptiveFlowControl.new(65536_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)

      # When not in burst and no stalls, should use predictive allocation
      flow_control.metrics.burst_detected = false
      flow_control.metrics.stall_count = 0
      flow_control.metrics.rate_variance = 1000.0 # Low variance

      # Calculate increment - should use predictive path
      increment = flow_control.calculate_increment(45536_i64, 20000_i64)

      # Increment should be reasonable
      increment.should be >= 20000  # At least what was consumed
      increment.should be <= 131072 # Max is 2x initial window
    end

    it "handles high variance consumption" do
      flow_control = HT2::AdaptiveFlowControl.new(65536_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)

      # Set high variance condition
      flow_control.metrics.rate_variance = 40000.0 # High variance

      # Calculate increment with high variance
      increment = flow_control.calculate_increment(30000_i64, 35000_i64)

      # Should allocate for peak consumption due to high variance
      increment.should be >= 49152 # At least 75% of window
    end

    it "maintains bounds on increment calculation" do
      flow_control = HT2::AdaptiveFlowControl.new(65536_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)

      # Even with extreme consumption
      increment = flow_control.calculate_increment(1000_i64, 64536_i64)

      # Should respect max increment bounds
      increment.should be <= 131072 # 2x initial window
      increment.should be >= 16384  # At least 1/4 initial window
    end

    it "gradually converges threshold for normal consumption" do
      flow_control = HT2::AdaptiveFlowControl.new(65536_i64, HT2::AdaptiveFlowControl::Strategy::DYNAMIC)
      flow_control.current_threshold = 0.8 # Start high

      # Simulate normal steady consumption with longer intervals
      30.times do
        flow_control.needs_update?(65536_i64, 32768_i64)
        flow_control.calculate_increment(32768_i64, 16384_i64)
        sleep 50.milliseconds # Give more time for rate calculation
      end

      # Should converge toward moderate threshold (0.5)
      # With longer convergence time
      flow_control.current_threshold.should be < 0.75
      flow_control.current_threshold.should be > 0.35
    end
  end
end
