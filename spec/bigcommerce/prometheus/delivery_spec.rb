# frozen_string_literal: true

# Copyright (c) 2019-present, BigCommerce Pty. Ltd. All rights reserved
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
# documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
# persons to whom the Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
# Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
# WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
# OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
require 'spec_helper'

describe Bigcommerce::Prometheus::Delivery do
  let(:queue) { Queue.new }
  let(:host) { '127.0.0.1' }
  let(:port) { 9394 }
  let(:flush_timeout) { 0.02 }
  let(:prometheus_logger) { instance_double(Logger, warn: nil) }

  let(:delivery) do
    described_class.new(
      queue: queue,
      host: host,
      port: port,
      flush_timeout: flush_timeout,
      process_name: 'test'
    )
  end

  let(:delivery_mutex) { delivery.instance_variable_get(:@delivery_mutex) }

  before { allow(Bigcommerce::Prometheus).to receive(:logger).and_return(prometheus_logger) }

  describe '#flush!' do
    context 'when nothing is queued' do
      it 'sends nothing, so a caller that never pushed pays nothing' do
        allow(Net::HTTP).to receive(:new)
        delivery.flush!
        expect(Net::HTTP).not_to have_received(:new)
      end

      # :empty and :success are separate outcomes so a caller can distinguish between a flush that didn't send any
      # metrics and one that sent metrics and got them delivered.
      # Reached only after taking the delivery lock, never by short-circuiting on an empty queue.
      it 'reports :empty' do
        allow(Net::HTTP).to receive(:new)
        expect(delivery.flush!).to eq :empty
      end
    end

    # Several examples below need one thread to have reached a known point before another thread acts.
    # A `Latch` makes that wait explicit, rather than sleeping for a guessed duration and hoping the other thread got
    # far enough. Sleeping makes the interleaving likely. A latch makes it certain.
    #
    # `await` blocks until another thread calls `signal`.
    #
    # The `Thread::Queue` in Latch is just a mechanism to implement the Latch and totally unrelated to the metric delivery queue.
    class Latch
      def initialize
        @queue = Thread::Queue.new
      end

      # Releases a thread blocked in `await`, since its `pop` now has something to take.
      # Signaling before any thread awaits is also safe.
      # The value stays on the queue, and the next `await` returns immediately.
      def signal
        @queue << true
      end

      def await
        @queue.pop
      end
    end

    context 'when the background thread is part way through a delivery' do
      # The background child delivery thread can be in the process of sending metrics when `flush!` is invoked.
      # The queue is empty from the moment the background thread pops the last message until that request completes.
      # As such, an empty queue doesn't guarantee that all metrics have been sent, just that there are no more to send.
      #
      # flush! waits on the delivery lock prior to running.
      # This ensures that flush! doesn't just detect an empty queue and return allowing the process to exit
      # whilst the child delivery thread is in the process of sending metrics.
      #
      # The latches coordinate the two threads, so this example can ensure the interleaving it needs.
      let(:delivery_started) { Latch.new }
      let(:finish_delivery) { Latch.new }

      # Generous, because this example is about waiting rather than about the deadline that bounds the wait.
      let(:flush_timeout) { 5 }

      before do
        allow(delivery).to receive(:post_message) do
          delivery_started.signal
          finish_delivery.await
        end
        queue << 'in_flight_message'
      end

      it 'does not return until that delivery has finished' do
        Thread.new { delivery.process_queue }
        delivery_started.await

        flusher = Thread.new { delivery.flush! }
        # A broken `flush!` that returned as soon as the queue looked empty would return in under a millisecond.
        # Finding it still blocked after 200ms is therefore good evidence that it is waiting on the delivery lock.
        # The 200ms is a margin over that near-instant return, not a measurement of anything.
        expect(flusher.join(0.2)).to be_nil

        finish_delivery.signal
        expect(flusher.join(2)).to eq flusher
      end
    end

    context 'when messages are queued' do
      before do
        allow(delivery).to receive(:post_message)
        queue << 'queued_message'
      end

      it 'delivers them on the calling thread' do
        delivery.flush!
        expect(delivery).to have_received(:post_message).with('queued_message', timeout: anything)
      end

      it 'reports :success' do
        expect(delivery.flush!).to eq :success
      end
    end

    context 'when the collector cannot be reached' do
      before do
        allow(delivery).to receive(:post_message).and_raise(StandardError, 'collector unreachable')
        queue << 'queued_message'
      end

      it 'does not raise into the caller, since a lost metric must not fail the work that produced it' do
        expect { delivery.flush! }.not_to raise_error
      end

      it 'reports :error' do
        expect(delivery.flush!).to eq :error
      end

      it 'reports the failed send once, from where it actually happened' do
        delivery.flush!
        expect(prometheus_logger).to have_received(:warn).with(/dropping a message.*collector unreachable/)
      end

      # `report_outcome` logs nothing when the outcome is `:error` and the queue is empty.
      # `drain` has already logged the exception in its own warning, so it does not need to be logged a second time.
      # The warning it skips describes giving up while waiting on an in-flight background send.
      # A `drain` that raised never had a send in flight, so that description would be wrong.
      it 'does not also report it as a lock wait on an in-flight send' do
        delivery.flush!
        expect(prometheus_logger).not_to have_received(:warn).with(/in-flight send/)
      end
    end

    # `drain` reports only the message it was carrying when it failed, then re-raises.
    # Everything behind that message stays on the queue.
    # `report_outcome` counts those and logs them even when the outcome is `:error`, so the metrics the child's
    # `exit!` will destroy are logged first.
    context 'when a send fails part way through, leaving messages behind it on the queue' do
      before do
        allow(delivery).to receive(:post_message).and_raise(StandardError, 'collector unreachable')
        3.times { |i| queue << "queued_message_#{i}" }
      end

      it 'counts the ones it never got to, not just the one that failed' do
        delivery.flush!
        expect(prometheus_logger).to have_received(:warn).with(/abandoned 2 metric/)
      end
    end

    context 'when a delivery is in flight for longer than the flush timeout' do
      let(:lock_taken) { Latch.new }

      before do
        queue << 'stranded_message'

        @lock_holder = Thread.new do
          delivery_mutex.lock
          lock_taken.signal
          sleep
        end
        lock_taken.await
      end

      after do
        @lock_holder.kill
        @lock_holder.join
      end

      it 'gives up, so an unhealthy collector cannot hold the caller up indefinitely' do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        delivery.flush!
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 1
      end

      it 'says how many observations it abandoned, since nothing else will report them' do
        delivery.flush!
        expect(prometheus_logger).to have_received(:warn).with(/abandoned 1 metric/)
      end

      it 'reports :timeout' do
        expect(delivery.flush!).to eq :timeout
      end
    end

    # The regression this exists to catch. `@queue.size` cannot see the message the background thread has already
    # popped and is sending, so counting the queue alone reported "nothing abandoned" in the one case where something
    # is: the process is about to `exit!` and destroy that request.
    context 'when the lock cannot be taken and nothing is left on the queue' do
      let(:lock_taken) { Latch.new }

      before do
        @lock_holder = Thread.new do
          delivery_mutex.lock
          lock_taken.signal
          sleep
        end
        lock_taken.await
      end

      after do
        @lock_holder.kill
        @lock_holder.join
      end

      it 'reports :timeout rather than :empty, since the queue being empty is not the same as nothing being lost' do
        expect(delivery.flush!).to eq :timeout
      end

      it 'says something was lost, rather than staying silent on a count of zero' do
        delivery.flush!
        expect(prometheus_logger).to have_received(:warn).with(/in-flight send/)
      end
    end

    context 'with a collector that does not answer' do
      let(:http) do
        instance_double(Net::HTTP, :open_timeout= => nil, :read_timeout= => nil, :write_timeout= => nil, start: nil)
      end

      before do
        allow(Net::HTTP).to receive(:new).and_return(http)
        queue << 'queued_message'
      end

      it 'bounds an inline flush on what is left of its budget, not on the Net::HTTP defaults' do
        delivery.flush!
        expect(http).to have_received(:read_timeout=).with(a_value_between(0, flush_timeout))
      end
    end
  end

  describe '#process_queue' do
    let(:http) do
      instance_double(Net::HTTP, :open_timeout= => nil, :read_timeout= => nil, :write_timeout= => nil, start: nil)
    end

    before do
      allow(Net::HTTP).to receive(:new).and_return(http)
      queue << 'queued_message'
    end

    # `process_queue` passes no timeout, so `Net::HTTP`'s defaults apply, as they always have in this gem.
    # Nothing waits on the background thread, so there is no reason to shorten those timeouts.
    # Shortening them would change delivery timing for every user of the gem, including those who never enable the
    # flush.
    it 'leaves the connect timeout at the Net::HTTP default' do
      delivery.process_queue
      expect(http).not_to have_received(:open_timeout=)
    end

    it 'leaves the response timeout at the Net::HTTP default' do
      delivery.process_queue
      expect(http).not_to have_received(:read_timeout=)
    end

    it 'leaves the send timeout at the Net::HTTP default' do
      delivery.process_queue
      expect(http).not_to have_received(:write_timeout=)
    end
  end

  describe '#flush! against a collector that stops answering' do
    # A real socket that accepts and then never replies, which is what a saturated exporter looks like.
    # Timeouts run against the clock, so a stub cannot show that the bound holds.
    # Without it this example takes as long as `Net::HTTP`'s 60 second read default.
    let(:stalled_collector) { TCPServer.new('127.0.0.1', 0) }
    let(:port) { stalled_collector.addr[1] }

    before do
      @accepted = []
      @acceptor = Thread.new { loop { @accepted << stalled_collector.accept } }
      queue << 'queued_message'
    end

    after do
      @acceptor.kill
      @accepted.each(&:close)
      stalled_collector.close
    end

    it 'gives up on the flush timeout rather than on the much longer read timeout' do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      delivery.flush!
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      expect(elapsed).to be < 0.1
    end

    # Two paths can end this flush, and which comes first is not deterministic.
    # `post_message` passes the remaining budget to `Net::HTTP`, so the request itself can time out.
    # `drain` then logs the message it was carrying, and the outcome is `:error`.
    # Alternatively, `attempt_flush_within_budget` reaches its `join(@flush_timeout)` first and kills the thread.
    # `report_outcome` then logs an in-flight send, and the outcome is `:timeout`.
    # Both warnings say an observation was lost, which is what this example checks.
    # Matching only one would assert which path won rather than the behavior.
    it 'says something was lost, so an outage is not silent' do
      delivery.flush!
      expect(prometheus_logger).to have_received(:warn).with(/dropping a message|in-flight send/)
    end
  end
  describe '#flush! when delivery overruns the budget' do
    # `Net::HTTP`'s own timeouts do not cover a whole request and response, so the budget is enforced by stopping
    # the thread doing the delivering. Without that the caller waits for however long the request takes.
    before do
      allow(delivery).to receive(:attempt_flush) { sleep 5 }
      queue << 'queued_message'
    end

    it 'gives up at the budget rather than waiting for the delivery to finish' do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      delivery.flush!
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      expect(elapsed).to be < 0.1
    end

    it 'reports :timeout, since the observations went nowhere' do
      expect(delivery.flush!).to eq :timeout
    end

    it 'says what was abandoned, rather than leaving the loss silent' do
      delivery.flush!
      expect(prometheus_logger).to have_received(:warn).with(/abandoned 1 metric/)
    end

    it 'leaves the delivery lock free, so a stopped thread cannot wedge the next flush' do
      delivery.flush!
      expect(delivery_mutex).not_to be_locked
    end
  end

  # A mutex held by a thread that dies is released by the VM, so a stopped flush cannot strand the delivery lock.
  # A stranded lock would make every later `flush!` in the process wait out its whole budget and send nothing.
  # A forked Resque child flushes once and exits, so this protects longer-lived callers rather than that path.
  describe '#flush! when the thread is stopped while it holds the delivery lock' do
    before do
      allow(delivery).to receive(:post_message) { sleep 5 }
      queue << 'queued_message'
    end

    it 'reports :timeout' do
      expect(delivery.flush!).to eq :timeout
    end

    it 'releases the delivery lock, so the next flush is not locked out by a thread that no longer exists' do
      delivery.flush!

      # Stopping a thread only schedules its unwind, so `flush!` can return before the lock has come back.
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.001 while delivery_mutex.locked? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

      expect(delivery_mutex).not_to be_locked
    end
  end
end
