require "./frame"

module HT2
  # LibC bindings for vectored I/O operations
  lib LibC
    {% if flag?(:bits64) %}
      alias SizeT = UInt64
      alias SSizeT = Int64
    {% else %}
      alias SizeT = UInt32
      alias SSizeT = Int32
    {% end %}

    struct IOVec
      base : Void*
      len : SizeT
    end

    fun writev(fd : Int32, iov : IOVec*, iovcnt : Int32) : SSizeT
    fun readv(fd : Int32, iov : IOVec*, iovcnt : Int32) : SSizeT
  end

  # Provides vectored I/O operations for efficient multi-buffer writes
  module VectoredIO
    # Maximum number of IOVec structures per writev call (platform dependent)
    # Most systems support at least 1024, but we use a conservative limit
    MAX_IOV_COUNT = 1024

    # Write multiple byte slices in a single system call
    def self.writev(io : IO::FileDescriptor, slices : Array(Bytes)) : Int64
      return 0_i64 if slices.empty?

      total_written = 0_i64
      offset = 0

      while offset < slices.size
        # Batch up to MAX_IOV_COUNT slices
        batch_size = Math.min(slices.size - offset, MAX_IOV_COUNT)
        batch = slices[offset, batch_size]

        # Create IOVec array
        iovecs = batch.map do |slice|
          LibC::IOVec.new(
            base: slice.to_unsafe.as(Void*),
            len: slice.size
          )
        end

        # Perform vectored write
        bytes_written = LibC.writev(io.fd, iovecs.to_unsafe, batch_size)

        if bytes_written < 0
          # Handle error cases
          errno = Errno.value
          if errno.in?(Errno::EAGAIN, Errno::EWOULDBLOCK)
            # Would block, retry later
            break if total_written > 0
            raise IO::Error.from_errno("writev")
          else
            raise IO::Error.from_errno("writev")
          end
        elsif bytes_written == 0
          # EOF
          break
        else
          total_written += bytes_written
          offset += batch_size

          # Check if partial write occurred
          if bytes_written < batch.sum(&.size)
            # Handle partial write by adjusting slices
            # This is complex and rare, so we fall back to regular writes
            break
          end
        end
      end

      total_written.to_i64
    end

    # Write multiple frames using vectored I/O
    def self.write_frames(io : IO::FileDescriptor, frames : Array(Frame), buffer_pool : BufferPool) : Int64
      return 0_i64 if frames.empty?

      # Serialize frames to byte slices
      slices = frames.map(&.to_bytes(buffer_pool))

      begin
        # Write all slices in one or more writev calls
        bytes_written = writev(io, slices)

        # If partial write, fall back to sequential writes
        total_size = slices.sum(&.size.to_i64)
        if bytes_written < total_size
          # Write remaining data sequentially
          written_so_far = bytes_written

          frames.each_with_index do |_frame, i|
            slice = slices[i]
            if written_so_far >= slice.size
              # This frame was fully written
              written_so_far -= slice.size
              next
            elsif written_so_far > 0
              # This frame was partially written
              io.write(slice[written_so_far..])
              written_so_far = 0
            else
              # This frame needs to be written
              io.write(slice)
            end
          end
        end

        total_size.to_i64
      ensure
        # Release buffers back to pool
        slices.each { |slice| buffer_pool.release(slice) }
      end
    end

    # Write DATA frames using vectored I/O with zero-copy optimization
    def self.write_data_frames(io : IO::FileDescriptor, frames : Array(DataFrame)) : Int64
      return 0_i64 if frames.empty?

      # Separate frames into headers and data slices
      slices = [] of Bytes

      frames.each do |frame|
        # Add frame header
        header = Bytes.new(Frame::HEADER_SIZE)
        header[0] = (frame.payload.size >> 16).to_u8
        header[1] = (frame.payload.size >> 8).to_u8
        header[2] = frame.payload.size.to_u8
        header[3] = frame.type.value.to_u8
        header[4] = frame.flags.value.to_u8
        header[5] = (frame.stream_id >> 24).to_u8
        header[6] = (frame.stream_id >> 16).to_u8
        header[7] = (frame.stream_id >> 8).to_u8
        header[8] = frame.stream_id.to_u8

        slices << header

        # Add padding length if present
        if frame.flags.padded?
          pad_length = Bytes.new(1)
          pad_length[0] = frame.padding
          slices << pad_length
        end

        # Add data payload (zero-copy)
        slices << frame.data if frame.data.size > 0

        # Add padding if present
        if frame.flags.padded? && frame.padding > 0
          padding = Bytes.new(frame.padding)
          slices << padding
        end
      end

      # Write all slices using vectored I/O
      writev(io, slices).to_i64
    end
  end
end
