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

      # Distinguished from :success so a caller can tell "the job recorded nothing" from "the job recorded something
      # and it arrived". Reached only after taking the delivery lock, never by short circuiting on an empty queue.
      it 'reports :empty' do
        allow(Net::HTTP).to receive(:new)
        expect(delivery.flush!).to eq :empty
      end
    end

    context 'when the background thread is part way through a delivery' do
      # The bug this exists to catch: `flush!` used to return as soon as the queue looked empty, and the queue looks
      # empty the instant the worker thread pops the last message, well before that message reaches the wire. A child
      # that exits at that point destroys the request.
      #
      # Rendezvous rather than sleeps, so the interleaving is fixed rather than hoped for. The only timing in the
      # example is the join timeout, which asserts a negative and is therefore generous.
      let(:entered_delivery) { Queue.new }
      let(:release_delivery) { Queue.new }

      # Generous, because this example is about waiting rather than about the deadline that bounds the wait.
      let(:flush_timeout) { 5 }

      before do
        allow(delivery).to receive(:post_message) do
          entered_delivery << true
          release_delivery.pop
        end
        queue << 'in_flight_message'
      end

      it 'does not return until that delivery has finished' do
        Thread.new { delivery.process_queue }
        entered_delivery.pop

        flusher = Thread.new { delivery.flush! }
        expect(flusher.join(0.2)).to be_nil

        release_delivery << true
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

      # The regression this exists to catch. `drain` already reports the specific exception; without excluding
      # `:error`, the message it emptied the queue on its way out of would additionally be misreported below as a
      # lock wait on an in-flight background send, when nothing was ever in flight.
      it 'does not also report it as a lock wait on an in-flight send' do
        delivery.flush!
        expect(prometheus_logger).not_to have_received(:warn).with(/in-flight send/)
      end
    end

    # The regression this exists to catch. `drain` reports only the message it was carrying when it failed, then
    # re-raises, leaving everything behind that message on the queue. Excluding `:error` from reporting entirely meant
    # those were destroyed by the child's `exit!` in silence, which is the one thing this reporting exists to prevent.
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
      let(:lock_taken) { Queue.new }

      before do
        queue << 'stranded_message'

        @lock_holder = Thread.new do
          delivery_mutex.lock
          lock_taken << true
          sleep
        end
        lock_taken.pop
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
      let(:lock_taken) { Queue.new }

      before do
        @lock_holder = Thread.new do
          delivery_mutex.lock
          lock_taken << true
          sleep
        end
        lock_taken.pop
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

    # Nothing waits on the background thread, so it keeps the 60 second defaults this gem has always sent
    # under. Shortening them here would re-time delivery for every existing user, including the ones who
    # never enable the flush.
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
    # A real socket that accepts and then never replies, which is what a saturated exporter looks like from here.
    # Timeouts run against the clock, so a stub cannot show that the bound holds. Without it this example takes as
    # long as `Net::HTTP`'s 60 second read default.
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

    it 'says the observation was dropped, so an outage is not silent' do
      delivery.flush!
      expect(prometheus_logger).to have_received(:warn).with(/dropping a message/)
    end
  end
  describe '#flush! when delivery overruns the budget' do
    # Per-phase timeouts cannot bound a request as a whole, so the budget is enforced by stopping the thread doing
    # the delivering. Without that the caller waits for however long the phases take between them.
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
end
