require "openssl"
require "socket"

module HT2
  # BufferedSocket wraps an IO to provide peeking functionality
  # without consuming bytes from the underlying socket.
  # This is essential for connection type detection in h2c.
  class BufferedSocket < IO
    getter io : IO
    @buffer : Bytes
    @buffer_pos : Int32
    @buffer_size : Int32
    @closed : Bool

    def initialize(@io : IO, initial_buffer_size : Int32 = 1024)
      @buffer = Bytes.new(initial_buffer_size)
      @buffer_pos = 0
      @buffer_size = 0
      @closed = false
    end

    # Peek at the first n bytes without consuming them
    def peek(n : Int32, timeout : Time::Span? = nil) : Bytes
      begin
        ensure_buffered(n, timeout)
      rescue IO::TimeoutError
        # Return what we have on timeout
      end
      @buffer[@buffer_pos, Math.min(n, @buffer_size - @buffer_pos)]
    end

    # Read bytes from the buffer first, then from the underlying IO
    def read(slice : Bytes) : Int32
      return 0 if @closed || slice.empty?

      bytes_read = 0

      # First, read from buffer if available
      if @buffer_pos < @buffer_size
        buffered_bytes = Math.min(slice.size, @buffer_size - @buffer_pos)
        slice[0, buffered_bytes].copy_from(@buffer[@buffer_pos, buffered_bytes])
        @buffer_pos += buffered_bytes
        bytes_read += buffered_bytes
      end

      # If more bytes needed, read directly from IO
      if bytes_read < slice.size
        direct_bytes = @io.read(slice[bytes_read, slice.size - bytes_read])
        bytes_read += direct_bytes
      end

      bytes_read
    end

    def write(slice : Bytes) : Nil
      @io.write(slice)
    end

    def close : Nil
      return if @closed
      @closed = true
      @io.close
    end

    def closed? : Bool
      @closed || @io.closed?
    end

    def flush : Nil
      @io.flush
    end

    private def ensure_buffered(n : Int32, timeout : Time::Span? = nil) : Nil
      return if @buffer_size - @buffer_pos >= n

      # Need more data in buffer
      if @buffer_pos > 0
        # Shift existing data to beginning
        remaining = @buffer_size - @buffer_pos
        @buffer[0, remaining].copy_from(@buffer[@buffer_pos, remaining])
        @buffer_size = remaining
        @buffer_pos = 0
      end

      # Resize buffer if needed
      needed_size = @buffer_pos + n
      if needed_size > @buffer.size
        new_buffer = Bytes.new(needed_size * 2)
        new_buffer[0, @buffer_size].copy_from(@buffer[0, @buffer_size])
        @buffer = new_buffer
      end

      # Handle timeout for socket types
      case io = @io
      when TCPSocket, OpenSSL::SSL::Socket::Client, OpenSSL::SSL::Socket::Server
        if timeout
          old_timeout = io.read_timeout
          begin
            io.read_timeout = timeout
            bytes_read = io.read(@buffer[@buffer_size, @buffer.size - @buffer_size])
            @buffer_size += bytes_read
          ensure
            io.read_timeout = old_timeout
          end
        else
          bytes_read = io.read(@buffer[@buffer_size, @buffer.size - @buffer_size])
          @buffer_size += bytes_read
        end
      else
        # For other IO types, just read without timeout
        bytes_read = @io.read(@buffer[@buffer_size, @buffer.size - @buffer_size])
        @buffer_size += bytes_read
      end
    end
  end
end
