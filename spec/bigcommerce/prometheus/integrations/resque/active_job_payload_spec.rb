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

describe Bigcommerce::Prometheus::Integrations::Resque::ActiveJobPayload do
  # Mirrors the inner hash ActiveJob's JobWrapper stamps into args[0].
  # JobPayload.for guarantees a truthy job_class before construction.
  def inner_payload(job_class: 'MyJob', enqueued_at: nil, scheduled_at: nil)
    {
      'job_class' => job_class,
      'arguments' => [],
      'enqueued_at' => enqueued_at,
      'scheduled_at' => scheduled_at
    }.compact
  end

  describe '#job_class' do
    it 'returns the inner job_class' do
      expect(described_class.new(inner_payload(job_class: 'BigPay::SomePublishJob')).job_class)
        .to eq('BigPay::SomePublishJob')
    end
  end

  describe '#anchor_time' do
    it 'prefers scheduled_at when both are present (excludes the intentional backoff)' do
      enqueued = (Time.now - 30).iso8601(6)
      scheduled = (Time.now - 1).iso8601(6)

      anchor = described_class.new(inner_payload(enqueued_at: enqueued, scheduled_at: scheduled)).anchor_time

      expect(anchor).to be_within(0.5).of(Time.now - 1)
    end

    it 'falls back to enqueued_at when scheduled_at is absent' do
      enqueued = (Time.now - 3).iso8601(6)

      anchor = described_class.new(inner_payload(enqueued_at: enqueued)).anchor_time

      expect(anchor).to be_within(0.5).of(Time.now - 3)
    end

    it 'returns nil when neither timestamp is present' do
      expect(described_class.new(inner_payload).anchor_time).to be_nil
    end

    it 'handles a Time instance directly in the payload' do
      time = Time.now - 2

      expect(described_class.new(inner_payload(enqueued_at: time)).anchor_time).to eq(time)
    end

    it 'returns nil for an unparseable string (no exception)' do
      expect do
        @anchor = described_class.new(inner_payload(enqueued_at: 'not a real time')).anchor_time
      end.not_to raise_error
      expect(@anchor).to be_nil
    end

    it 'returns nil for an empty string' do
      expect(described_class.new(inner_payload(enqueued_at: '')).anchor_time).to be_nil
    end
  end

  describe 'field independence under partial failure' do
    it 'still returns job_class when the enqueued_at timestamp is unparseable' do
      result = described_class.new(inner_payload(job_class: 'BigPay::SomeJob', enqueued_at: 'not a real time'))

      expect(result.job_class).to eq('BigPay::SomeJob')
      expect(result.anchor_time).to be_nil
    end
  end
end
