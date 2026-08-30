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

describe Bigcommerce::Prometheus::Client do
  let(:client) { described_class.instance }

  describe '#initialize' do
    subject { client }

    it 'initializes the client object from the singleton' do
      expect(subject).to be_a(described_class)
    end

    it 'behaves like a singleton' do
      ref1 = described_class.instance
      ref2 = described_class.instance
      expect(ref1).to eq ref2
    end
  end

  describe '#send' do
    context 'when prometheus is enabled' do
      before do
        allow(Bigcommerce::Prometheus).to receive(:enabled).and_return(true)
      end

      it 'sends a message to the Prometheus server' do
        expect { client.send('test_message') }.to change(client.instance_variable_get(:@queue), :size).by 1
      end
    end

    context 'when prometheus is disabled' do
      before do
        allow(Bigcommerce::Prometheus).to receive(:enabled).and_return(false)
      end

      it 'sends a message to the Prometheus server' do
        expect { client.send('test_message') }.not_to change(client.instance_variable_get(:@queue), :size)
      end
    end
  end

  describe '#flush!' do
    # Populated directly rather than through #send, which starts the background thread and would race the assertion.
    let(:queue) { client.instance_variable_get(:@queue) }

    let(:delivery_mutex) { client.instance_variable_get(:@delivery_mutex) }

    before do
      allow(Bigcommerce::Prometheus).to receive(:enabled).and_return(true)
      @original_flush_timeout = client.instance_variable_get(:@flush_timeout)
      client.reset_after_fork!
    end

    after do
      client.instance_variable_set(:@flush_timeout, @original_flush_timeout)
      client.reset_after_fork!
    end

    context 'when nothing is queued' do
      it 'sends nothing, so a caller that never pushed pays nothing' do
        allow(Net::HTTP).to receive(:new)
        client.flush!
        expect(Net::HTTP).not_to have_received(:new)
      end

      # Distinguished from :success so a caller can tell "the job recorded nothing" from "the job recorded something
      # and it arrived". Reached only after taking the delivery lock, never by short circuiting on an empty queue.
      it 'reports :empty' do
        allow(Net::HTTP).to receive(:new)
        expect(client.flush!).to eq :empty
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

      before do
        # Generous, because this example is about waiting rather than about the deadline that bounds the wait.
        client.instance_variable_set(:@flush_timeout, 5)
        allow(client).to receive(:post_message) do
          entered_delivery << true
          release_delivery.pop
        end
        queue << 'in_flight_message'
      end

      it 'does not return until that delivery has finished' do
        Thread.new { client.process_queue }
        entered_delivery.pop

        flusher = Thread.new { client.flush! }
        expect(flusher.join(0.2)).to be_nil

        release_delivery << true
        expect(flusher.join(2)).to eq flusher
      end
    end

    context 'when messages are queued' do
      before do
        allow(client).to receive(:post_message)
        queue << 'queued_message'
      end

      it 'delivers them on the calling thread' do
        client.flush!
        expect(client).to have_received(:post_message).with('queued_message', timeout: anything)
      end

      it 'reports :success' do
        expect(client.flush!).to eq :success
      end
    end

    context 'when the collector cannot be reached' do
      let(:prometheus_logger) { instance_double(Logger, warn: nil) }

      before do
        allow(Bigcommerce::Prometheus).to receive(:logger).and_return(prometheus_logger)
        allow(client).to receive(:post_message).and_raise(StandardError, 'collector unreachable')
        queue << 'queued_message'
      end

      it 'does not raise into the caller, since a lost metric must not fail the work that produced it' do
        expect { client.flush! }.not_to raise_error
      end

      it 'reports :error' do
        expect(client.flush!).to eq :error
      end

      it 'reports the failed send once, from where it actually happened' do
        client.flush!
        expect(prometheus_logger).to have_received(:warn).with(/dropping a message.*collector unreachable/)
      end

      # The regression this exists to catch. `drain` already reports the specific exception; without excluding
      # `:error`, the message it emptied the queue on its way out of would additionally be misreported below as a
      # lock wait on an in-flight background send, when nothing was ever in flight.
      it 'does not also report it as a lock wait on an in-flight send' do
        client.flush!
        expect(prometheus_logger).not_to have_received(:warn).with(/in-flight send/)
      end
    end

    # The regression this exists to catch. `drain` reports only the message it was carrying when it failed, then
    # re-raises, leaving everything behind that message on the queue. Excluding `:error` from reporting entirely meant
    # those were destroyed by the child's `exit!` in silence, which is the one thing this reporting exists to prevent.
    context 'when a send fails part way through, leaving messages behind it on the queue' do
      let(:prometheus_logger) { instance_double(Logger, warn: nil) }

      before do
        allow(Bigcommerce::Prometheus).to receive(:logger).and_return(prometheus_logger)
        allow(client).to receive(:post_message).and_raise(StandardError, 'collector unreachable')
        3.times { |i| queue << "queued_message_#{i}" }
      end

      it 'counts the ones it never got to, not just the one that failed' do
        client.flush!
        expect(prometheus_logger).to have_received(:warn).with(/abandoned 2 metric/)
      end
    end

    context 'when a delivery is in flight for longer than the flush timeout' do
      let(:prometheus_logger) { instance_double(Logger, warn: nil) }
      let(:lock_taken) { Queue.new }

      before do
        allow(Bigcommerce::Prometheus).to receive(:logger).and_return(prometheus_logger)
        client.instance_variable_set(:@flush_timeout, 0.02)
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
        client.flush!
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 1
      end

      it 'says how many observations it abandoned, since nothing else will report them' do
        client.flush!
        expect(prometheus_logger).to have_received(:warn).with(/abandoned 1 metric/)
      end

      it 'reports :timeout' do
        expect(client.flush!).to eq :timeout
      end
    end

    # The regression this exists to catch. `@queue.size` cannot see the message the background thread has already
    # popped and is sending, so counting the queue alone reported "nothing abandoned" in the one case where something
    # is: the process is about to `exit!` and destroy that request.
    context 'when the lock cannot be taken and nothing is left on the queue' do
      let(:prometheus_logger) { instance_double(Logger, warn: nil) }
      let(:lock_taken) { Queue.new }

      before do
        allow(Bigcommerce::Prometheus).to receive(:logger).and_return(prometheus_logger)
        client.instance_variable_set(:@flush_timeout, 0.02)

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
        expect(client.flush!).to eq :timeout
      end

      it 'says something was lost, rather than staying silent on a count of zero' do
        client.flush!
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

      it 'bounds an inline flush on what is left of its budget, not on the background timeouts' do
        client.instance_variable_set(:@flush_timeout, 0.02)
        client.flush!
        expect(http).to have_received(:read_timeout=).with(a_value_between(0, 0.02))
      end

      it 'bounds the background thread on the configured open timeout' do
        client.process_queue
        expect(http).to have_received(:open_timeout=).with(Bigcommerce::Prometheus.client_open_timeout)
      end

      it 'bounds the background thread on the configured read timeout' do
        client.process_queue
        expect(http).to have_received(:read_timeout=).with(Bigcommerce::Prometheus.client_read_timeout)
      end

      it 'bounds the write timeout, which Net::HTTP otherwise leaves at 60 seconds' do
        client.process_queue
        expect(http).to have_received(:write_timeout=).with(Bigcommerce::Prometheus.client_write_timeout)
      end
    end
  end

  describe '#flush! against a collector that stops answering' do
    # A real socket that accepts and then never replies, which is what a saturated exporter looks like from here.
    # Timeouts run against the clock, so a stub cannot show that the bound holds. Without it this example takes as
    # long as the read timeout, five seconds when it was written.
    let(:stalled_collector) { TCPServer.new('127.0.0.1', 0) }
    let(:prometheus_logger) { instance_double(Logger, warn: nil) }

    before do
      allow(Bigcommerce::Prometheus).to receive_messages(enabled: true, logger: prometheus_logger)
      @accepted = []
      @acceptor = Thread.new { loop { @accepted << stalled_collector.accept } }

      @original = %i[@host @port @flush_timeout].to_h { |name| [name, client.instance_variable_get(name)] }
      client.instance_variable_set(:@host, '127.0.0.1')
      client.instance_variable_set(:@port, stalled_collector.addr[1])
      client.instance_variable_set(:@flush_timeout, 0.02)
      client.reset_after_fork!
      client.instance_variable_get(:@queue) << 'queued_message'
    end

    after do
      @acceptor.kill
      @accepted.each(&:close)
      stalled_collector.close
      @original.each { |name, value| client.instance_variable_set(name, value) }
      client.reset_after_fork!
    end

    it 'gives up on the flush timeout rather than on the much longer read timeout' do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      client.flush!
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      expect(elapsed).to be < Bigcommerce::Prometheus.client_read_timeout
    end

    it 'says the observation was dropped, so an outage is not silent' do
      client.flush!
      expect(prometheus_logger).to have_received(:warn).with(/dropping a message/)
    end
  end

  describe '#reset_after_fork!' do
    before do
      allow(Bigcommerce::Prometheus).to receive(:enabled).and_return(true)
    end

    after { client.reset_after_fork! }

    it 'discards the messages a forked child inherited from its parent' do
      client.send('inherited_message')
      expect { client.reset_after_fork! }.to change { client.instance_variable_get(:@queue).size }.to 0
    end

    it 'replaces the queue rather than draining it, so the child never sends the parent messages' do
      original = client.instance_variable_get(:@queue)
      client.reset_after_fork!
      expect(client.instance_variable_get(:@queue)).not_to be original
    end

    it 'clears the inherited worker thread reference, since threads do not survive a fork' do
      client.send('inherited_message')
      client.reset_after_fork!
      expect(client.instance_variable_get(:@worker_thread)).to be_nil
    end

    it 'replaces a mutex that may have been held when the fork landed' do
      original = client.instance_variable_get(:@mutex)
      original.lock
      client.reset_after_fork!
      expect(client.instance_variable_get(:@mutex)).not_to be original
    end

    it 'leaves the replacement mutex unlocked, so the first push in the child cannot deadlock' do
      client.instance_variable_get(:@mutex).lock
      client.reset_after_fork!
      expect(client.instance_variable_get(:@mutex)).not_to be_locked
    end

    it 'replaces the delivery mutex too, so the first delivery in the child cannot deadlock' do
      client.instance_variable_get(:@delivery_mutex).lock
      client.reset_after_fork!
      expect(client.instance_variable_get(:@delivery_mutex)).not_to be_locked
    end

    context 'with socket state inherited from the parent' do
      before do
        client.instance_variable_set(:@socket, :inherited_socket)
        client.instance_variable_set(:@socket_started, Time.now.to_f)
        client.instance_variable_set(:@socket_pid, Process.pid)

        client.reset_after_fork!
      end

      it 'clears the socket' do
        expect(client.instance_variable_get(:@socket)).to be_nil
      end

      it 'clears the socket start time' do
        expect(client.instance_variable_get(:@socket_started)).to be_nil
      end

      it 'clears the socket pid' do
        expect(client.instance_variable_get(:@socket_pid)).to be_nil
      end
    end
  end
end
