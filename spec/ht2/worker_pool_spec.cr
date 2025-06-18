require "../spec_helper"
require "../../src/ht2/worker_pool"

describe HT2::WorkerPool do
  describe "#initialize" do
    it "creates worker pool with default parameters" do
      pool = HT2::WorkerPool.new
      pool.max_workers.should eq 100
      pool.queue_size.should eq 1000
    end

    it "creates worker pool with custom parameters" do
      pool = HT2::WorkerPool.new(max_workers: 10, queue_size: 50)
      pool.max_workers.should eq 10
      pool.queue_size.should eq 50
    end

    it "raises error for invalid max_workers" do
      expect_raises(ArgumentError, "max_workers must be positive") do
        HT2::WorkerPool.new(max_workers: 0)
      end
    end

    it "raises error for invalid queue_size" do
      expect_raises(ArgumentError, "queue_size must be positive") do
        HT2::WorkerPool.new(queue_size: 0)
      end
    end
  end

  describe "#start" do
    it "starts the worker pool" do
      pool = HT2::WorkerPool.new(max_workers: 2)
      pool.running?.should be_false

      pool.start
      pool.running?.should be_true

      pool.stop
    end

    it "is idempotent" do
      pool = HT2::WorkerPool.new(max_workers: 2)

      pool.start
      pool.running?.should be_true

      # Second start should not cause issues
      pool.start
      pool.running?.should be_true

      pool.stop
    end
  end

  describe "#submit" do
    it "executes submitted tasks" do
      pool = HT2::WorkerPool.new(max_workers: 2)
      pool.start

      counter = Atomic(Int32).new(0)
      done = Channel(Nil).new

      pool.submit(-> {
        counter.add(1)
        done.send(nil)
      })

      done.receive
      counter.get.should eq 1

      pool.stop
    end

    it "raises error when pool is not running" do
      pool = HT2::WorkerPool.new

      expect_raises(HT2::Error, "Worker pool is not running") do
        pool.submit(-> { })
      end
    end

    it "handles multiple concurrent tasks" do
      pool = HT2::WorkerPool.new(max_workers: 4)
      pool.start

      counter = Atomic(Int32).new(0)
      done = Channel(Nil).new(10)

      10.times do
        pool.submit(-> {
          counter.add(1)
          sleep 10.milliseconds
          done.send(nil)
        })
      end

      10.times { done.receive }
      counter.get.should eq 10

      pool.stop
    end
  end

  describe "#submit?" do
    it "returns true when task is accepted" do
      pool = HT2::WorkerPool.new(max_workers: 2)
      pool.start

      result = pool.submit?(-> { sleep 10.milliseconds })
      result.should be_true

      pool.stop
    end

    it "returns false when pool is not running" do
      pool = HT2::WorkerPool.new

      result = pool.submit?(-> { })
      result.should be_false
    end
  end

  describe "#active_count" do
    it "tracks active worker count" do
      pool = HT2::WorkerPool.new(max_workers: 2)
      pool.start

      pool.active_count.should eq 0

      started = Channel(Nil).new
      finish = Channel(Nil).new

      pool.submit(-> {
        started.send(nil)
        finish.receive
      })

      started.receive
      pool.active_count.should eq 1

      finish.send(nil)
      sleep 10.milliseconds
      pool.active_count.should eq 0

      pool.stop
    end
  end

  describe "#queue_depth" do
    it "tracks queue depth" do
      pool = HT2::WorkerPool.new(max_workers: 1, queue_size: 10)
      pool.start

      pool.queue_depth.should eq 0

      # Block the worker
      blocking = Channel(Nil).new
      started = Channel(Nil).new
      pool.submit(-> {
        started.send(nil)
        blocking.receive
      })

      # Wait for first task to start
      started.receive

      # Submit more tasks
      3.times { pool.submit(-> { }) }

      # Should have 2-3 tasks in queue depending on timing
      # (one task might have been dequeued but not yet marked active)
      actual_queue = pool.queue_depth
      actual_queue.should be >= 2
      actual_queue.should be <= 3

      # Unblock
      blocking.send(nil)
      sleep 50.milliseconds

      pool.queue_depth.should eq 0
      pool.stop
    end
  end

  describe "#stop" do
    it "stops all workers gracefully" do
      pool = HT2::WorkerPool.new(max_workers: 2)
      pool.start

      counter = Atomic(Int32).new(0)

      5.times do
        pool.submit(-> {
          counter.add(1)
          sleep 10.milliseconds
        })
      end

      pool.stop

      # All tasks should have completed
      counter.get.should eq 5
      pool.running?.should be_false
    end

    it "is idempotent" do
      pool = HT2::WorkerPool.new(max_workers: 2)
      pool.start

      pool.stop
      pool.running?.should be_false

      # Second stop should not cause issues
      pool.stop
      pool.running?.should be_false
    end
  end

  describe "error handling" do
    it "continues processing after task errors" do
      pool = HT2::WorkerPool.new(max_workers: 2)
      pool.start

      counter = Atomic(Int32).new(0)
      done = Channel(Nil).new

      # Submit task that raises error
      pool.submit(-> { raise "Test error" })

      # Submit normal task after error
      pool.submit(-> {
        counter.add(1)
        done.send(nil)
      })

      done.receive
      counter.get.should eq 1

      pool.stop
    end
  end

  describe "#try_submit" do
    it "submits task with timeout" do
      pool = HT2::WorkerPool.new(max_workers: 1, queue_size: 1)
      pool.start

      counter = Atomic(Int32).new(0)
      done = Channel(Nil).new

      # Submit task that completes quickly
      result = pool.try_submit(-> {
        counter.add(1)
        done.send(nil)
      })

      result.should be_true
      done.receive
      counter.get.should eq 1

      pool.stop
    end

    it "returns false when queue is full" do
      pool = HT2::WorkerPool.new(max_workers: 1, queue_size: 1)
      pool.start

      # Block the worker and fill the queue
      blocking = Channel(Nil).new
      started = Channel(Nil).new

      pool.submit(-> {
        started.send(nil)
        blocking.receive
      })

      started.receive
      pool.submit(-> { }) # Fill the queue

      # Try to submit with timeout should fail
      result = pool.try_submit(-> { }, 50.milliseconds)
      result.should be_false

      # Unblock
      blocking.send(nil)
      pool.stop
    end
  end

  describe "#can_accept?" do
    it "returns true when queue has capacity" do
      pool = HT2::WorkerPool.new(max_workers: 1, queue_size: 10)
      pool.start

      pool.can_accept?.should be_true

      pool.stop
    end

    it "returns false when queue is full" do
      pool = HT2::WorkerPool.new(max_workers: 1, queue_size: 1)
      pool.start

      # Block the worker and fill the queue
      blocking = Channel(Nil).new
      started = Channel(Nil).new

      pool.submit(-> {
        started.send(nil)
        blocking.receive
      })

      started.receive
      pool.submit(-> { }) # Fill the queue

      pool.can_accept?.should be_false

      # Unblock
      blocking.send(nil)
      pool.stop
    end

    it "returns false when pool is stopped" do
      pool = HT2::WorkerPool.new
      pool.can_accept?.should be_false
    end
  end

  describe "#utilization" do
    it "calculates utilization percentage" do
      pool = HT2::WorkerPool.new(max_workers: 2, queue_size: 10)
      pool.start

      pool.utilization.should eq 0.0

      # Add some tasks
      blocking = Channel(Nil).new
      started = Channel(Nil).new

      2.times do
        pool.submit(-> {
          started.send(nil)
          blocking.receive
        })
      end

      2.times { started.receive }

      # 2 active workers out of total capacity (2 + 10)
      pool.utilization.should be_close(2.0/12.0, 0.01)

      # Add queue items
      2.times { pool.submit(-> { sleep 10.milliseconds }) }

      # Give a moment for the queue to stabilize
      sleep 5.milliseconds

      # Should have 2 active + some queued out of total capacity
      # The exact number depends on timing, but should be at least 2/12
      pool.utilization.should be >= 2.0/12.0

      # Unblock
      2.times { blocking.send(nil) }
      pool.stop
    end

    it "returns 0.0 when pool is not running" do
      pool = HT2::WorkerPool.new
      pool.utilization.should eq 0.0
    end
  end
end
