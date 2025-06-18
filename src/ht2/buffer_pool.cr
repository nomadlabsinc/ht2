module HT2
  # Thread-safe pool of reusable byte buffers to reduce memory allocations
  # during frame processing operations.
  class BufferPool
    @available : Array(Bytes)
    @mutex : Mutex

    def initialize(
      @max_pool_size : Int32 = 100,
      @max_buffer_size : Int32 = 16_384,
    )
      @available = Array(Bytes).new
      @mutex = Mutex.new
    end

    # Acquire a buffer of at least the specified size
    def acquire(size : Int32) : Bytes
      return Bytes.new(size) if size > @max_buffer_size

      @mutex.synchronize do
        # Find suitable buffer
        index = @available.index { |buf| buf.size >= size }
        if index
          buffer = @available.delete_at(index)
          # Clear buffer before reuse
          buffer.fill(0_u8, 0, size)
          return buffer[0, size]
        end
      end

      # No suitable buffer found, allocate new one
      Bytes.new(size)
    end

    # Release a buffer back to the pool
    def release(buffer : Bytes) : Nil
      return if buffer.size > @max_buffer_size

      @mutex.synchronize do
        if @available.size < @max_pool_size
          @available << buffer
        end
      end
    end

    # Get current pool statistics
    def stats : NamedTuple(available: Int32, max_size: Int32)
      @mutex.synchronize do
        {available: @available.size, max_size: @max_pool_size}
      end
    end

    # Clear all buffers from the pool
    def clear : Nil
      @mutex.synchronize do
        @available.clear
      end
    end
  end
end
