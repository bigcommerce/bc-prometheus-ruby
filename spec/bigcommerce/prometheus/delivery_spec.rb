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
  let(:prometheus_logger) { instance_double(Logger, warn: nil) }

  let(:delivery) do
    described_class.new(
      queue: queue,
      host: host,
      port: port,
      process_name: 'spec'
    )
  end

  before { allow(Bigcommerce::Prometheus).to receive(:logger).and_return(prometheus_logger) }

  describe '#process_queue' do
    before { allow(Net::HTTP).to receive(:post) }

    it 'posts every queued message to the collector' do
      queue << 'first_message'
      queue << 'second_message'

      delivery.process_queue

      expect(Net::HTTP).to have_received(:post).with(delivery.uri_path('/send-metrics'), 'first_message')
      expect(Net::HTTP).to have_received(:post).with(delivery.uri_path('/send-metrics'), 'second_message')
    end

    it 'empties the queue, so the next pass does not re-send what it already delivered' do
      queue << 'queued_message'

      expect { delivery.process_queue }.to change(queue, :size).to 0
    end

    it 'sends nothing when nothing is queued' do
      delivery.process_queue

      expect(Net::HTTP).not_to have_received(:post)
    end
  end

  describe '#process_queue when the collector cannot be reached' do
    before { allow(Net::HTTP).to receive(:post).and_raise(Errno::ECONNREFUSED) }

    it 'raises, leaving the client worker loop to decide what to do' do
      queue << 'queued_message'

      expect { delivery.process_queue }.to raise_error(Errno::ECONNREFUSED)
    end

    it 'names the message it dropped, since nothing downstream will ever see it' do
      queue << 'queued_message'

      expect { delivery.process_queue }.to raise_error(Errno::ECONNREFUSED)
      expect(prometheus_logger).to have_received(:warn).with(/dropping a message to/)
    end
  end
end
