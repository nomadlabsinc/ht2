require "./errors"

module HT2
  # A bounded worker pool for handling stream processing with configurable concurrency limits.
  # This prevents unbounded fiber creation and provides backpressure for slow consumers.
  class WorkerPool
    alias Task = -> Nil

    getter max_workers : Int32
    getter queue_size : Int32

    @queue : Channel(Task?)
    @workers : Array(Fiber)
    @running : Bool
    @active_count : Atomic(Int32)
    @queued_count : Atomic(Int32)
    @mutex : Mutex

    def initialize(@max_workers : Int32 = 100, @queue_size : Int32 = 1000)
      raise ArgumentError.new("max_workers must be positive") unless @max_workers > 0
      raise ArgumentError.new("queue_size must be positive") unless @queue_size > 0

      @queue = Channel(Task?).new(@queue_size)
      @workers = [] of Fiber
      @running = false
      @active_count = Atomic(Int32).new(0)
      @queued_count = Atomic(Int32).new(0)
      @mutex = Mutex.new
    end

    def start : Nil
      @mutex.synchronize do
        return if @running
        @running = true

        @max_workers.times do
          worker = spawn_worker
          @workers << worker
        end
      end
    end

    def stop : Nil
      @mutex.synchronize do
        return unless @running
        @running = false
      end

      # Send nil to all workers to signal shutdown first
      @max_workers.times { @queue.send(nil) rescue nil }

      # Then wait for completion with a timeout
      wait_for_completion(timeout: 1.second)
    end

    def submit(task : Task) : Nil
      raise Error.new("Worker pool is not running") unless @running

      begin
        @queued_count.add(1)
        @queue.send(task)
      rescue Channel::ClosedError
        @queued_count.sub(1)
        raise Error.new("Worker pool is shutting down")
      end
    end

    def submit?(task : Task) : Bool
      return false unless @running

      begin
        @queued_count.add(1)
        @queue.send(task)
        true
      rescue Channel::ClosedError
        @queued_count.sub(1)
        false
      end
    end

    def try_submit(task : Task, timeout : Time::Span = 50.milliseconds) : Bool
      return false unless @running
      try_send_with_timeout(task, timeout)
    end

    private def try_send_with_timeout(task : Task, timeout : Time::Span) : Bool
      @queued_count.add(1)

      select
      when @queue.send(task)
        true
      when timeout(timeout)
        @queued_count.sub(1)
        false
      end
    rescue Channel::ClosedError
      @queued_count.sub(1)
      false
    end

    def can_accept? : Bool
      @running && @queued_count.get < @queue_size
    end

    def utilization : Float64
      return 0.0 unless @running
      total_used = active_count.to_f + queue_depth.to_f
      total_capacity = @max_workers.to_f + @queue_size.to_f
      total_used / total_capacity
    end

    def active_count : Int32
      @active_count.get
    end

    def queue_depth : Int32
      # Queued count includes both active and waiting tasks
      # So queue depth is total queued minus those actively being processed
      Math.max(0, @queued_count.get - @active_count.get)
    end

    def total_queued : Int32
      @queued_count.get
    end

    def running? : Bool
      @running
    end

    private def spawn_worker : Fiber
      spawn do
        loop do
          task = @queue.receive?
          break unless task

          @queued_count.sub(1)
          @active_count.add(1)
          begin
            task.call
          rescue ex
            # Log error but continue processing
            puts "Worker pool task error: #{ex.message}"
          ensure
            @active_count.sub(1)
          end
        end
      end
    end

    private def wait_for_completion(timeout : Time::Span = 30.seconds) : Nil
      deadline = Time.utc + timeout

      loop do
        break if @active_count.get == 0 && queue_depth == 0
        break if Time.utc > deadline

        sleep 10.milliseconds
      end
    end
  end
end
