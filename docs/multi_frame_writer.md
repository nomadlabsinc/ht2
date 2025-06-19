# Multi-Frame Writer

The Multi-Frame Writer is a performance optimization module for HTTP/2 frame writing that reduces system calls and improves throughput by batching multiple frames into single I/O operations.

## Features

- **Batched Frame Writing**: Combines multiple frames into single write operations
- **Zero-Copy DATA Frames**: Optimized path for DATA frames without padding
- **Priority Support**: Send frames in priority order  
- **Thread-Safe**: Safe for concurrent use with mutex protection
- **Memory Efficient**: Uses buffer pools to minimize allocations

## Usage

### Basic Usage

```crystal
# Create a writer with a buffer pool
pool = HT2::BufferPool.new
writer = HT2::MultiFrameWriter.new(pool)

# Add frames to the writer
writer.add_frame(ping_frame)
writer.add_frame(settings_frame)
writer.add_frame(data_frame)

# Flush all frames to an IO
writer.flush_to(socket)

# Release resources
writer.release
```

### Connection Integration

The `Connection` class provides methods for efficient multi-frame operations:

```crystal
# Send multiple frames at once
frames = [
  WindowUpdateFrame.new(0_u32, 65535_u32),
  PingFrame.new(Bytes.new(8)),
  SettingsFrame.new(FrameFlags::ACK)
]
connection.send_frames(frames)

# Send prioritized frames
prioritized = [
  MultiFrameWriter::PrioritizedFrame.new(urgent_frame, priority: 10),
  MultiFrameWriter::PrioritizedFrame.new(normal_frame, priority: 5),
  MultiFrameWriter::PrioritizedFrame.new(low_priority_frame, priority: 1)
]
connection.send_prioritized_frames(prioritized)

# Send multiple DATA frames efficiently
data_chunks = [chunk1, chunk2, chunk3]
connection.send_data_frames(stream_id, data_chunks, end_stream: true)
```

### Stream Integration

Streams can send multiple data chunks efficiently:

```crystal
# Send data using multiple frames
chunks = [
  "First chunk".to_slice,
  "Second chunk".to_slice,
  "Final chunk".to_slice
]
stream.send_data_multi(chunks, end_stream: true)
```

## Performance Benefits

The multi-frame writer provides significant performance improvements:

1. **Reduced System Calls**: Batching frames reduces the number of write() system calls
2. **Improved Throughput**: Less overhead means more data transferred per second
3. **Better CPU Utilization**: Fewer context switches between user and kernel space
4. **Memory Efficiency**: Buffer pooling reduces garbage collection pressure

### Benchmark Results

Based on benchmarks, the multi-frame writer provides:

- Up to 2-3x speedup for small frame batches
- 50-90% reduction in system calls
- Significant improvement for high-frequency frame scenarios

## Implementation Details

### Frame Queuing

The writer maintains separate queues for different frame types:

- `pending_data_frames`: DATA frames without padding (zero-copy path)
- `pending_other_frames`: All other frame types

### Zero-Copy Optimization

DATA frames without padding use a zero-copy path that writes the frame header and payload separately without intermediate copying:

```crystal
# Zero-copy write for DATA frames
MultiFrameWriter.write_data_frames(io, stream_id, data_chunks, end_stream: true)
```

### Buffer Management

The writer uses a buffer pool to minimize allocations:

```crystal
# Frames are serialized using pooled buffers
frame_bytes = frame.to_bytes(@buffer_pool)
io.write(frame_bytes)
@buffer_pool.release(frame_bytes)
```

## Best Practices

1. **Batch Related Frames**: Group frames that are logically related (e.g., HEADERS + DATA)
2. **Use Priorities**: For frames that need ordering, use the priority system
3. **Release Resources**: Always call `release()` when done with a writer
4. **Consider Buffer Size**: Larger buffers mean fewer flushes but more memory usage

## Thread Safety

The MultiFrameWriter is thread-safe and can be used from multiple fibers concurrently. All operations are protected by a mutex to ensure data consistency.

## Future Enhancements

Potential improvements for the multi-frame writer:

1. **Automatic CONTINUATION**: Split large HEADERS automatically
2. **Vectored I/O**: Use writev() for even better performance
3. **Adaptive Batching**: Dynamically adjust batch sizes based on workload
4. **Frame Coalescing**: Combine small frames into larger payloads