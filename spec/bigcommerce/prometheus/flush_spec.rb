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

describe Bigcommerce::Prometheus::Flush do
  let(:queue) { Queue.new }
  let(:host) { '127.0.0.1' }
  let(:port) { 9394 }
  let(:timeout) { 0.02 }

  let(:delivery) { Bigcommerce::Prometheus::Delivery.new(queue: queue, host: host, port: port) }
  let(:delivery_mutex) { delivery.instance_variable_get(:@delivery_mutex) }

  let(:flush) { described_class.new(delivery: delivery, timeout: timeout) }

  class Latch
    def initialize
      @queue = Thread::Queue.new
    end

    def signal
      @queue << true
    end

    def await
      @queue.pop
    end
  end

  describe '#call' do
    context 'when nothing is queued' do
      before { allow(Net::HTTP).to receive(:post) }

      it 'sends nothing, so a caller that never pushed pays nothing' do
        flush.call

        expect(Net::HTTP).not_to have_received(:post)
      end

      it 'reports :empty' do
        expect(flush.call).to be_empty
      end

      it 'has no message worth logging' do
        expect(flush.call.message).to be_nil
      end
    end

    context 'when messages are queued' do
      before do
        allow(delivery).to receive(:post_message)
        queue << 'queued_message'
      end

      it 'delivers them on the calling thread' do
        flush.call

        expect(delivery).to have_received(:post_message).with('queued_message')
      end

      it 'reports :success' do
        expect(flush.call).to be_success
      end

      it 'has no message worth logging' do
        expect(flush.call.message).to be_nil
      end
    end

    context 'when the background thread is part way through a delivery' do
      let(:delivery_started) { Latch.new }
      let(:finish_delivery) { Latch.new }
      let(:timeout) { 5 }

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

        flusher = Thread.new { flush.call }
        expect(flusher.join(0.2)).to be_nil

        finish_delivery.signal
        expect(flusher.join(2)).to eq flusher
      end
    end

    context 'when the collector cannot be reached' do
      before do
        allow(delivery).to receive(:post_message).and_raise(StandardError, 'collector unreachable')
        queue << 'queued_message'
      end

      it 'does not raise into the caller, since a lost metric must not fail the work that produced it' do
        expect { flush.call }.not_to raise_error
      end

      it 'reports :error' do
        expect(flush.call).to be_error
      end

      it 'names the message it dropped, from where the send actually failed, as the outcome message' do
        expect(flush.call.message).to match(/dropping a message.*collector unreachable/)
      end
    end

    context 'when a send fails part way through, leaving messages behind it on the queue' do
      before do
        allow(delivery).to receive(:post_message).and_raise(StandardError, 'collector unreachable')
        3.times { |i| queue << "queued_message_#{i}" }
      end

      it 'counts the ones it never got to, not just the one that failed' do
        expect(flush.call.message).to match(/2 more left undelivered/)
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
        flush.call

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 1
      end

      it 'reports the in-flight send as well as what is stuck behind it' do
        expect(flush.call.message).to match(/in_flight=1 undelivered=1/)
      end

      it 'carries the collector URL as context rather than in the message' do
        expect(flush.call.context).to eq(uri: delivery.uri_path('/send-metrics'))
      end

      it 'reports :timeout' do
        expect(flush.call).to be_timeout
      end
    end

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

      it 'reports :timeout rather than :empty, since an empty queue is not the same as nothing being lost' do
        expect(flush.call).to be_timeout
      end

      it 'reports the loss even though the queue length alone would say otherwise' do
        expect(flush.call.message).to match(/in_flight=1/)
      end

      it 'says explicitly that undelivered is zero, rather than omitting the count' do
        expect(flush.call.message).to match(/undelivered=0/)
      end
    end
  end

  describe '#call against a collector that stops answering' do
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
      flush.call
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      expect(elapsed).to be < 0.1
    end

    it 'says something was lost, so an outage is not silent' do
      expect(flush.call.message).to match(/in_flight=1/)
    end
  end

  describe '#call when delivery overruns the budget' do
    before do
      allow(delivery).to receive(:process_queue) { sleep 5 }
      queue << 'queued_message'
    end

    it 'gives up at the budget rather than waiting for the delivery to finish' do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      flush.call
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      expect(elapsed).to be < 0.1
    end

    it 'reports :timeout, since the observations went nowhere' do
      expect(flush.call).to be_timeout
    end

    it 'says what was abandoned, rather than leaving the loss silent' do
      expect(flush.call.message).to match(/undelivered=1/)
    end

    it 'leaves the delivery lock free, so a stopped thread cannot wedge the next flush' do
      flush.call

      expect(delivery_mutex).not_to be_locked
    end
  end

  describe '#call when the thread is stopped while it holds the delivery lock' do
    before do
      allow(delivery).to receive(:post_message) { sleep 5 }
      queue << 'queued_message'
    end

    it 'reports :timeout' do
      expect(flush.call).to be_timeout
    end

    it 'releases the delivery lock, so the next flush is not locked out by a thread that no longer exists' do
      flush.call

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      sleep 0.001 while delivery_mutex.locked? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline

      expect(delivery_mutex).not_to be_locked
    end
  end
end
