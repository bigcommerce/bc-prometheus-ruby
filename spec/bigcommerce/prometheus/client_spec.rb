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
