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
end
