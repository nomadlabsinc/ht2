module HT2
  # Manages adaptive buffer sizing based on connection patterns
  class AdaptiveBufferManager
    # Common buffer size buckets
    BUFFER_SIZES = [4_096, 8_192, 16_384, 32_768, 65_536, 131_072]

    # Default sizes
    DEFAULT_READ_BUFFER_SIZE  = 16_384
    DEFAULT_WRITE_BUFFER_SIZE = 65_536
    DEFAULT_CHUNK_SIZE        = 16_384

    # Adaptation parameters
    MIN_SAMPLES       =  10
    ADAPTATION_FACTOR = 1.5

    @mutex : Mutex
    @read_sizes : Array(Int32)
    @write_sizes : Array(Int32)
    @frame_sizes : Array(Int32)

    def initialize
      @mutex = Mutex.new
      @read_sizes = Array(Int32).new
      @write_sizes = Array(Int32).new
      @frame_sizes = Array(Int32).new
      @last_adaptation = Time.monotonic - 11.seconds # Allow immediate adaptation
    end

    # Record an observed frame size
    def record_frame_size(size : Int32) : Nil
      @mutex.synchronize do
        @frame_sizes << size
        maintain_window(@frame_sizes)
      end
    end

    # Record a write operation size
    def record_write_size(size : Int32) : Nil
      @mutex.synchronize do
        @write_sizes << size
        maintain_window(@write_sizes)
      end
    end

    # Get recommended read buffer size
    def recommended_read_buffer_size : Int32
      @mutex.synchronize do
        return DEFAULT_READ_BUFFER_SIZE if @frame_sizes.size < MIN_SAMPLES

        # Calculate percentile-based size
        percentile_95 = calculate_percentile(@frame_sizes, 0.95)
        find_optimal_bucket(percentile_95)
      end
    end

    # Get recommended write buffer size
    def recommended_write_buffer_size : Int32
      @mutex.synchronize do
        return DEFAULT_WRITE_BUFFER_SIZE if @write_sizes.size < MIN_SAMPLES

        # Use 90th percentile for write buffer
        percentile_90 = calculate_percentile(@write_sizes, 0.90)
        find_optimal_bucket(percentile_90)
      end
    end

    # Get recommended chunk size for stream data
    def recommended_chunk_size(available_window : Int32) : Int32
      @mutex.synchronize do
        # Start with window-based size
        base_size = [available_window, DEFAULT_CHUNK_SIZE].min

        # Adapt based on observed frame sizes if we have enough data
        if @frame_sizes.size >= MIN_SAMPLES
          avg_frame = @frame_sizes.sum / @frame_sizes.size
          base_size = [base_size, (avg_frame * ADAPTATION_FACTOR).to_i].min
        end

        # Align to power of 2 for efficiency
        align_to_power_of_two(base_size)
      end
    end

    # Check if adaptation is needed
    def should_adapt? : Bool
      (Time.monotonic - @last_adaptation).total_seconds > 10
    end

    # Get current statistics
    def stats : NamedTuple(
      frame_samples: Int32,
      write_samples: Int32,
      avg_frame_size: Int32?,
      avg_write_size: Int32?)
      @mutex.synchronize do
        {
          frame_samples:  @frame_sizes.size,
          write_samples:  @write_sizes.size,
          avg_frame_size: @frame_sizes.empty? ? nil : (@frame_sizes.sum / @frame_sizes.size).to_i,
          avg_write_size: @write_sizes.empty? ? nil : (@write_sizes.sum / @write_sizes.size).to_i,
        }
      end
    end

    # Clear all recorded data
    def clear : Nil
      @mutex.synchronize do
        @read_sizes.clear
        @write_sizes.clear
        @frame_sizes.clear
      end
    end

    private def maintain_window(array : Array(Int32), max_size : Int32 = 1000) : Nil
      array.shift if array.size > max_size
    end

    private def calculate_percentile(values : Array(Int32), percentile : Float64) : Int32
      return 0 if values.empty?

      sorted = values.sort
      index = ((sorted.size - 1) * percentile).to_i
      sorted[index]
    end

    private def find_optimal_bucket(size : Int32) : Int32
      # Find the smallest bucket that fits
      BUFFER_SIZES.find { |bucket| bucket >= size } || BUFFER_SIZES.last
    end

    private def align_to_power_of_two(size : Int32) : Int32
      return 0 if size <= 0

      # Find next power of 2
      power = Math.log2(size).ceil.to_i
      1 << power
    end
  end
end
