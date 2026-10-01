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

  let(:delivery) { described_class.new(queue: queue, host: host, port: port) }

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

    it 'reports :empty when nothing was queued' do
      expect(delivery.process_queue).to eq :empty
    end

    it 'reports :success once everything queued has been posted' do
      queue << 'queued_message'

      expect(delivery.process_queue).to eq :success
    end
  end

  describe '#process_queue when the collector cannot be reached' do
    before { allow(Net::HTTP).to receive(:post).and_raise(Errno::ECONNREFUSED) }

    it 'raises a Delivery::PostFailed' do
      queue << 'queued_message'

      expect { delivery.process_queue }.to raise_error(Bigcommerce::Prometheus::Delivery::PostFailed)
    end

    it 'names the message it dropped in the error' do
      queue << 'queued_message'

      expect { delivery.process_queue }.to raise_error(/dropping a message to/)
    end

    it 'reports the number of messages which will be discarded due to the failure' do
      queue << 'queued_message'
      queue << 'stranded_message'

      expect { delivery.process_queue }.to raise_error do |error|
        expect(error.sent).to eq 0
        expect(error.undelivered).to eq 1
      end
    end
  end

  describe '#queue_size' do
    it 'reports how many messages are currently queued' do
      queue << 'first_message'
      queue << 'second_message'

      expect(delivery.queue_size).to eq 2
    end
  end
end
