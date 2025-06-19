require "./spec_helper"

describe HT2::AdaptiveBufferManager do
  describe "#initialize" do
    it "creates an empty manager" do
      manager = HT2::AdaptiveBufferManager.new
      stats = manager.stats

      stats[:frame_samples].should eq(0)
      stats[:write_samples].should eq(0)
      stats[:avg_frame_size].should be_nil
      stats[:avg_write_size].should be_nil
    end
  end

  describe "#record_frame_size" do
    it "records frame sizes" do
      manager = HT2::AdaptiveBufferManager.new

      manager.record_frame_size(1024)
      manager.record_frame_size(2048)
      manager.record_frame_size(4096)

      stats = manager.stats
      stats[:frame_samples].should eq(3)
      stats[:avg_frame_size].should eq(2389) # (1024 + 2048 + 4096) / 3
    end

    it "maintains a sliding window of samples" do
      manager = HT2::AdaptiveBufferManager.new

      # Add more than max window size (1000)
      1001.times { |i| manager.record_frame_size(100 + i) }

      stats = manager.stats
      stats[:frame_samples].should eq(1000)
    end
  end

  describe "#record_write_size" do
    it "records write sizes" do
      manager = HT2::AdaptiveBufferManager.new

      manager.record_write_size(8192)
      manager.record_write_size(16384)

      stats = manager.stats
      stats[:write_samples].should eq(2)
      stats[:avg_write_size].should eq(12288)
    end
  end

  describe "#recommended_read_buffer_size" do
    it "returns default size with insufficient samples" do
      manager = HT2::AdaptiveBufferManager.new

      # Add less than MIN_SAMPLES
      5.times { manager.record_frame_size(1024) }

      manager.recommended_read_buffer_size.should eq(HT2::AdaptiveBufferManager::DEFAULT_READ_BUFFER_SIZE)
    end

    it "returns appropriate bucket size based on 95th percentile" do
      manager = HT2::AdaptiveBufferManager.new

      # Add samples with most around 6KB, but a few larger
      95.times { manager.record_frame_size(6_000) }
      5.times { manager.record_frame_size(20_000) }

      # Should pick 8192 bucket (smallest that fits 95th percentile)
      # 95th percentile of 100 samples = index 94, which is still 6000
      manager.recommended_read_buffer_size.should eq(8_192)
    end

    it "handles all small frames" do
      manager = HT2::AdaptiveBufferManager.new

      # All small frames
      100.times { manager.record_frame_size(100) }

      # Should pick smallest bucket
      manager.recommended_read_buffer_size.should eq(4_096)
    end

    it "handles very large frames" do
      manager = HT2::AdaptiveBufferManager.new

      # All large frames
      100.times { manager.record_frame_size(100_000) }

      # Should pick largest bucket
      manager.recommended_read_buffer_size.should eq(131_072)
    end
  end

  describe "#recommended_write_buffer_size" do
    it "returns default size with insufficient samples" do
      manager = HT2::AdaptiveBufferManager.new

      manager.recommended_write_buffer_size.should eq(HT2::AdaptiveBufferManager::DEFAULT_WRITE_BUFFER_SIZE)
    end

    it "adapts based on write patterns" do
      manager = HT2::AdaptiveBufferManager.new

      # Simulate write patterns
      50.times { manager.record_write_size(30_000) }
      50.times { manager.record_write_size(50_000) }

      # Should pick 65536 bucket for 90th percentile
      manager.recommended_write_buffer_size.should eq(65_536)
    end
  end

  describe "#recommended_chunk_size" do
    it "respects available window" do
      manager = HT2::AdaptiveBufferManager.new

      # Without history, should return min of window and default
      manager.recommended_chunk_size(8_192).should eq(8_192)
      manager.recommended_chunk_size(32_768).should eq(16_384) # DEFAULT_CHUNK_SIZE
    end

    it "adapts based on frame history" do
      manager = HT2::AdaptiveBufferManager.new

      # Add frame history
      20.times { manager.record_frame_size(4_096) }

      # Should adapt based on average * factor, aligned to power of 2
      # avg = 4096, * 1.5 = 6144, aligned = 8192
      manager.recommended_chunk_size(65_536).should eq(8_192)
    end

    it "aligns to power of two" do
      manager = HT2::AdaptiveBufferManager.new

      # Add specific frame sizes
      20.times { manager.record_frame_size(5_000) }

      # avg = 5000, * 1.5 = 7500, aligned to next power of 2 = 8192
      manager.recommended_chunk_size(65_536).should eq(8_192)
    end
  end

  describe "#should_adapt?" do
    it "returns true after time threshold" do
      manager = HT2::AdaptiveBufferManager.new

      # Should be true initially
      manager.should_adapt?.should be_true
    end
  end

  describe "#clear" do
    it "clears all recorded data" do
      manager = HT2::AdaptiveBufferManager.new

      # Add some data
      manager.record_frame_size(1024)
      manager.record_write_size(2048)

      # Clear
      manager.clear

      stats = manager.stats
      stats[:frame_samples].should eq(0)
      stats[:write_samples].should eq(0)
    end
  end

  describe "thread safety" do
    it "handles concurrent access" do
      manager = HT2::AdaptiveBufferManager.new

      # Spawn multiple fibers recording data
      spawn_count = 10
      records_per_fiber = 100

      done = Channel(Nil).new(spawn_count)

      spawn_count.times do |i|
        spawn do
          records_per_fiber.times do |j|
            manager.record_frame_size(1000 + i * 10 + j)
            manager.record_write_size(2000 + i * 10 + j)
          end
          done.send(nil)
        end
      end

      # Wait for all fibers
      spawn_count.times { done.receive }

      stats = manager.stats
      stats[:frame_samples].should eq(spawn_count * records_per_fiber)
      stats[:write_samples].should eq(spawn_count * records_per_fiber)
    end
  end
end
