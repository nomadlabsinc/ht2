require "./buffer_pool"
require "./frame"
require "./frames"
require "./vectored_io"
require "./zero_copy"

module HT2
  # Optimized multi-frame writer that batches frame writes to minimize I/O operations
  # and memory allocations. Supports zero-copy for DATA frames and efficient
  # serialization for other frame types.
  class MultiFrameWriter
    # Frame with priority for ordered sending
    struct PrioritizedFrame
      getter frame : Frame
      getter priority : Int32

      def initialize(@frame : Frame, @priority : Int32 = 0)
      end
    end

    # Default write buffer size (64KB)
    DEFAULT_BUFFER_SIZE = 65_536

    # Maximum frames to batch before forcing a flush
    MAX_BATCH_SIZE = 100

    getter buffer_pool : BufferPool
    getter write_buffer : Bytes
    getter write_mutex : Mutex

    private getter pending_data_frames : Array(DataFrame)
    private getter pending_other_frames : Array(Frame)

    def initialize(@buffer_pool : BufferPool, buffer_size : Int32 = DEFAULT_BUFFER_SIZE)
      @write_buffer = @buffer_pool.acquire(buffer_size)
      @write_mutex = Mutex.new
      @pending_data_frames = Array(DataFrame).new
      @pending_other_frames = Array(Frame).new
    end

    # Add a single frame to the write queue
    def add_frame(frame : Frame) : Nil
      @write_mutex.synchronize do
        # Special handling for DATA frames without padding
        if frame.is_a?(DataFrame) && !frame.flags.padded?
          @pending_data_frames << frame
        else
          @pending_other_frames << frame
        end
      end
    end

    # Add multiple frames at once
    def add_frames(frames : Array(Frame)) : Nil
      frames.each { |frame| add_frame(frame) }
    end

    # Add prioritized frames that will be sent in priority order
    def add_prioritized_frames(frames : Array(PrioritizedFrame)) : Nil
      # Sort by priority (higher priority first)
      sorted = frames.sort { |frame_a, frame_b| frame_b.priority <=> frame_a.priority }
      add_frames(sorted.map(&.frame))
    end

    # Flush all pending frames to the given IO
    def flush_to(io : IO) : Nil
      @write_mutex.synchronize do
        flush_internal_to(io)
      end
    end

    # Get the number of bytes currently buffered
    def buffered_bytes : Int32
      @write_mutex.synchronize do
        other_bytes = @pending_other_frames.sum { |frame| Frame::HEADER_SIZE + frame.payload.size }
        other_bytes + pending_data_bytes
      end
    end

    # Get the number of frames currently buffered
    def buffered_frames : Int32
      @write_mutex.synchronize do
        @pending_other_frames.size + @pending_data_frames.size
      end
    end

    # Release resources back to buffer pool
    def release : Nil
      @write_mutex.synchronize do
        @buffer_pool.release(@write_buffer)
        @write_buffer = Bytes.new(0)
      end
    end

    private def serialize_frames_to_buffer(frames : Array(Frame), io : IO) : Nil
      # Use a single buffer for all frames
      frames.each do |frame|
        frame_bytes = frame.to_bytes(@buffer_pool)
        io.write(frame_bytes)
        @buffer_pool.release(frame_bytes)
      end
    end

    private def flush_internal_to(io : IO) : Nil
      # Use vectored I/O if available for file descriptors
      if io.is_a?(IO::FileDescriptor) && (@pending_other_frames.size > 1 || @pending_data_frames.size > 1)
        flush_vectored_to(io)
      else
        # Fall back to sequential writes
        flush_sequential_to(io)
      end

      io.flush
    end

    private def flush_sequential_to(io : IO) : Nil
      # First serialize other frames
      serialize_frames_to_buffer(@pending_other_frames, io)
      @pending_other_frames.clear

      # Then write pending DATA frames using zero-copy
      @pending_data_frames.each do |data_frame|
        data_frame.write_to(io)
      end
      @pending_data_frames.clear
    end

    private def flush_vectored_to(io : IO::FileDescriptor) : Nil
      # Write non-DATA frames using vectored I/O
      if @pending_other_frames.size > 0
        VectoredIO.write_frames(io, @pending_other_frames, @buffer_pool)
        @pending_other_frames.clear
      end

      # Write DATA frames using optimized vectored I/O
      if @pending_data_frames.size > 0
        VectoredIO.write_data_frames(io, @pending_data_frames)
        @pending_data_frames.clear
      end
    end

    private def pending_data_bytes : Int32
      @pending_data_frames.sum { |frame| Frame::HEADER_SIZE + frame.data.size }
    end

    # Optimized batch writer for multiple DATA frames from the same stream
    def self.write_data_frames(io : IO, stream_id : UInt32, data_chunks : Array(Bytes),
                               end_stream : Bool = false) : Nil
      return if data_chunks.empty?

      data_chunks.each_with_index do |chunk, index|
        is_last = index == data_chunks.size - 1
        flags = is_last && end_stream ? FrameFlags::END_STREAM : FrameFlags::None

        # Use zero-copy forwarding
        ZeroCopy.forward_data_frame(chunk, flags, io, stream_id)
      end

      io.flush
    end

    # Optimized writer for HEADERS + CONTINUATION frames
    def self.write_headers_with_continuations(io : IO, stream_id : UInt32,
                                              header_block : Bytes,
                                              end_stream : Bool = false,
                                              priority : PriorityData? = nil,
                                              max_frame_size : UInt32 = DEFAULT_MAX_FRAME_SIZE) : Nil
      # Calculate how much header data fits in first HEADERS frame
      priority_size = priority ? 5 : 0
      first_frame_capacity = max_frame_size - priority_size

      if header_block.size <= first_frame_capacity
        # Fits in single HEADERS frame
        flags = FrameFlags::END_HEADERS
        flags = flags | FrameFlags::END_STREAM if end_stream

        headers_frame = HeadersFrame.new(stream_id, header_block, flags, 0_u8, priority)
        headers_frame.write_to(io)
      else
        # Need HEADERS + CONTINUATION frames
        offset = 0

        # First HEADERS frame (without END_HEADERS)
        flags = end_stream ? FrameFlags::END_STREAM : FrameFlags::None
        first_block = header_block[0, first_frame_capacity]
        headers_frame = HeadersFrame.new(stream_id, first_block, flags, 0_u8, priority)
        headers_frame.write_to(io)
        offset = first_frame_capacity

        # CONTINUATION frames
        while offset < header_block.size
          remaining = header_block.size - offset
          chunk_size = Math.min(remaining.to_u32, max_frame_size).to_i32
          is_last = offset + chunk_size >= header_block.size

          cont_flags = is_last ? FrameFlags::END_HEADERS : FrameFlags::None
          cont_block = header_block[offset, chunk_size]
          cont_frame = ContinuationFrame.new(stream_id, cont_block, cont_flags)
          cont_frame.write_to(io)

          offset += chunk_size
        end
      end

      io.flush
    end

    # Create a connection-specific writer
    def self.for_connection(connection : Connection) : MultiFrameWriter
      new(connection.buffer_pool)
    end
  end
end
