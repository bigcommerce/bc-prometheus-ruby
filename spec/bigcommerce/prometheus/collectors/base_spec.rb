# frozen_string_literal: true

# Copyright (c) 2020-present, BigCommerce Pty. Ltd. All rights reserved
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

describe Bigcommerce::Prometheus::Collectors::Base do
  let(:client) { double(:client, send_json: true) }
  let(:collector) { Test::DynamicCollector.new(client: client, frequency: 0) }

  describe '.run' do
    subject { collector.run }

    it 'should collect and push the metrics, then sleep the frequency' do
      expect(client).to receive(:send_json).with(
        type: 'test_dynamic',
        bonks: 42
      ).once
      subject
    end
  end

  describe '.add_widget' do
    subject { collector.add_widget }

    it 'should push the metric dynamically' do
      expect(client).to receive(:send_json).with(
        type: 'test_dynamic',
        widgets: 1,
        custom_labels: {
          shape: 'round'
        }
      ).once
      subject
    end
  end
end
