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

  # The client owns a `Delivery` and delegates sending to it.
  # These examples check that delegation, and that a forked child gets a fresh `Delivery` rather than the inherited one.
  let(:delivery) { client.instance_variable_get(:@delivery) }

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
    it 'delivers on the calling thread and passes the outcome back to the caller' do
      allow(delivery).to receive(:flush!).and_return(:success)
      expect(client.flush!).to eq :success
    end
  end

  describe '#process_queue' do
    it 'delegates to the delivery, which owns the path to the collector' do
      allow(delivery).to receive(:process_queue)
      client.process_queue
      expect(delivery).to have_received(:process_queue)
    end
  end

  describe '#uri_path' do
    it 'answers the collector URL the delivery would post to' do
      expect(client.uri_path('/send-metrics')).to eq delivery.uri_path('/send-metrics')
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

    it 'replaces a mutex that the parent may have been holding at the moment of the fork' do
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

    # The delivery owns the mutex that serializes sending.
    # A fork copies that mutex in whatever state it was in, but only the forking thread survives.
    # So if the parent's background thread was mid-send, the child starts with a locked mutex and no thread that can
    # unlock it.
    # The child's first flush would then poll the lock until its whole budget expired, without sending anything.
    it 'replaces the delivery, so the child does not inherit the lock or the queue behind it' do
      original = client.instance_variable_get(:@delivery)
      client.reset_after_fork!
      expect(client.instance_variable_get(:@delivery)).not_to be original
    end

    it 'points the replacement delivery at the replacement queue' do
      client.reset_after_fork!
      expect(client.instance_variable_get(:@delivery).instance_variable_get(:@queue))
        .to be client.instance_variable_get(:@queue)
    end
  end
end
