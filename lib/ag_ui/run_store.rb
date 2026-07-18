# frozen_string_literal: true

require "bundler/setup"
require "async"
require "async/queue"
require "ag_ui"

module AgUi
  # Per-thread run bookkeeping backing /connect (replay + live attach) and
  # /stop (cancel the run's Async task) — the Ruby counterpart of the Node
  # runtime's InMemoryAgentRunner thread store.
  #
  # The interface is duck-typed; hosts can supply anything implementing
  # begin_run / record / finish_run / attach_task / stop /
  # open_subscription (e.g. a redis-backed store) via
  # `AgUi.agent(store: ...)`.
  module RunStore
    # Single-process store. Fiber/thread-safe: state mutations are locked,
    # and live fanout uses Async::Queue so connect streams receive events
    # as they are recorded.
    class InMemory
      FINISHED = :finished

      def initialize
        @threads = Hash.new do |hash, key|
          hash[key] = { historic: [], live: nil, task: nil, subscribers: [] }
        end
        @mutex = Mutex.new
      end

      def begin_run(thread_id, run_id)
        @mutex.synchronize do
          @threads[thread_id][:live] = { run_id: run_id, events: [] }
        end
      end

      def record(thread_id, payload)
        subscribers = @mutex.synchronize do
          thread = @threads[thread_id]
          if thread[:live]
            thread[:live][:events] << payload
            thread[:subscribers].dup
          else
            []
          end
        end
        subscribers.each { |queue| queue.enqueue(payload) }
      end

      def finish_run(thread_id)
        subscribers = @mutex.synchronize do
          thread = @threads[thread_id]
          if thread[:live]
            thread[:historic] << thread[:live]
            thread[:live] = nil
          end
          thread[:task] = nil
          drained = thread[:subscribers]
          thread[:subscribers] = []
          drained
        end
        subscribers.each { |queue| queue.enqueue(FINISHED) }
      end

      # Only meaningful while the run is live — a late attach (the builder
      # calls on_task after Async returns, which for an already-completed
      # run is after finish_run) must not resurrect a stopped handle.
      def attach_task(thread_id, task)
        @mutex.synchronize do
          if @threads[thread_id][:live]
            @threads[thread_id][:task] = task
          end
        end
      end

      # Cancel the thread's in-flight run. The stream still closes cleanly
      # (StreamBuilder's ensure) — matching the Node runtime, which ends
      # an aborted run with a plain RUN_FINISHED-then-close.
      def stop(thread_id)
        task = @mutex.synchronize { @threads[thread_id][:task] }
        if task
          task.stop
          true
        else
          false
        end
      end

      # Atomic snapshot + live subscription: the returned events are
      # everything recorded so far (historic runs + the live run's events),
      # and when a run is in flight, queue receives each subsequent event
      # and finally FINISHED. Atomicity means no gap and no duplicates
      # between snapshot and subscription.
      def open_subscription(thread_id)
        @mutex.synchronize do
          thread = @threads[thread_id]
          events = thread[:historic].flat_map { |run| run[:events] }
          queue = nil
          if thread[:live]
            events += thread[:live][:events]
            queue = Async::Queue.new
            thread[:subscribers] << queue
          end
          { events: events, queue: queue }
        end
      end
    end
  end
end

__END__

describe "AgUi::RunStore::InMemory" do
  it "replays historic runs in order for a thread" do
    store = AgUi::RunStore::InMemory.new
    store.begin_run("t1", "r1")
    store.record("t1", { "type" => "RUN_STARTED" })
    store.record("t1", { "type" => "RUN_FINISHED" })
    store.finish_run("t1")
    store.begin_run("t1", "r2")
    store.record("t1", { "type" => "RUN_STARTED" })
    store.finish_run("t1")

    subscription = store.open_subscription("t1")
    subscription[:events].map { |e| e["type"] }.should == %w[RUN_STARTED RUN_FINISHED RUN_STARTED]
    subscription[:queue].should.be.nil
  end

  it "returns an empty snapshot for unknown threads" do
    subscription = AgUi::RunStore::InMemory.new.open_subscription("nope")
    subscription[:events].should == []
    subscription[:queue].should.be.nil
  end

  it "fans live events out to subscribers, with FINISHED at run end" do
    store = AgUi::RunStore::InMemory.new
    store.begin_run("t1", "r1")
    store.record("t1", { "type" => "RUN_STARTED" })

    received = []
    Async do |task|
      subscription = store.open_subscription("t1")
      subscription[:events].length.should == 1
      queue = subscription[:queue]

      reader = task.async do
        loop do
          item = queue.dequeue
          if item == AgUi::RunStore::InMemory::FINISHED
            break
          end
          received << item
        end
      end

      store.record("t1", { "type" => "TEXT_MESSAGE_START" })
      store.finish_run("t1")
      reader.wait
    end

    received.map { |e| e["type"] }.should == ["TEXT_MESSAGE_START"]
  end

  it "stops the attached task exactly while a run is live" do
    store = AgUi::RunStore::InMemory.new
    stopped = false
    fake_task = Object.new
    fake_task.define_singleton_method(:stop) { stopped = true }

    store.stop("t1").should == false

    store.begin_run("t1", "r1")
    store.attach_task("t1", fake_task)
    store.stop("t1").should == true
    stopped.should == true

    store.finish_run("t1")
    store.stop("t1").should == false
  end
end
