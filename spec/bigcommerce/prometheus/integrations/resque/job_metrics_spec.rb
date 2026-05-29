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

# NOTE: this spec deliberately does not `require 'resque'`. Pulling Resque
# into this gem's dev bundle conflicts with the gemspec's `rack >= 3.0`
# requirement (Resque -> sinatra (old) -> rack < 3 under cold bundle
# resolution). See the PR description for the testing-gap implications.
#
# We test the pure logic in JobMetrics (anchor selection, payload unwrapping,
# label assembly, error rescue) by injecting a client directly via
# `instance_variable_set(:@client, ...)` rather than calling `.start`, which
# would invoke `::Resque.before_fork` and `::Resque::Worker.prepend`. The
# `.start` install behaviour itself is not tested in this gem until Resque
# can be added to the dev bundle (blocked on bumping the Sinatra dep — see
# follow-up).

describe Bigcommerce::Prometheus::Integrations::Resque::JobMetrics do
  let(:client) { instance_double(PrometheusExporter::Client, send_json: nil) }

  before do
    # Inject the client directly. We can't go through `.start` because that
    # would call ::Resque::Worker.prepend, which is unavailable in this gem's
    # dev bundle. The production code path is the same once `@client` is set.
    described_class.instance_variable_set(:@client, client)
  end

  after do
    described_class.instance_variable_set(:@client, nil)
  end

  # A minimal stand-in for Resque::Job — the production code only ever calls
  # `.payload` on it, so a plain double is sufficient.
  def resque_job_double(payload)
    double('Resque::Job', payload: payload)
  end

  # Build a real JobPayload from a payload hash. Both record_* methods take
  # a JobPayload instance (the WorkerInstrumentation prepend constructs it
  # once per job and shares it between the two recordings); JobPayload's own
  # parsing edge cases are covered in job_payload_spec.rb.
  def payload_for(payload_hash)
    Bigcommerce::Prometheus::Integrations::Resque::JobPayload.new(resque_job_double(payload_hash))
  end

  def active_job_payload(job_class: 'MyJob', enqueued_at: nil, scheduled_at: nil)
    {
      'class' => 'ActiveJob::QueueAdapters::ResqueAdapter::JobWrapper',
      'args' => [
        {
          'job_class' => job_class,
          'arguments' => [],
          'enqueued_at' => enqueued_at,
          'scheduled_at' => scheduled_at
        }.compact
      ]
    }
  end

  # Payload-shape edge cases (anchor selection, ActiveJob unwrapping, time
  # parsing) are covered directly in job_payload_spec.rb. Tests here focus
  # on JobMetrics's distinct responsibilities: envelope shape, gating,
  # error rescue, and the JobMetrics → JobPayload integration.

  describe '.record_queue_latency' do
    it 'pushes the correct envelope for an ActiveJob-shaped payload' do
      enqueued = (Time.now - 3).iso8601(6)

      expect(client).to receive(:send_json).with(
        type: 'resque_job',
        metric: 'queue_latency',
        value: a_value_within(0.5).of(3),
        custom_labels: { job_class: 'MyJob' }
      )

      described_class.record_queue_latency(payload_for(active_job_payload(enqueued_at: enqueued)))
    end

    it 'is a no-op for a vanilla Resque payload (no anchor available, no exception)' do
      payload = { 'class' => 'RawResqueJob', 'args' => [12345, 'some_string'] }

      expect(client).not_to receive(:send_json)

      expect do
        described_class.record_queue_latency(payload_for(payload))
      end.not_to raise_error
    end

    context 'when client.send_json raises' do
      it 'rescues the error and logs a warning' do
        allow(client).to receive(:send_json).and_raise(StandardError, 'boom')
        expect(Bigcommerce::Prometheus.logger).to receive(:warn).with(/queue_latency push failed: boom/)

        expect do
          described_class.record_queue_latency(
            payload_for(active_job_payload(enqueued_at: Time.now.iso8601(6)))
          )
        end.not_to raise_error
      end
    end
  end

  describe '.record_perform_duration' do
    it 'pushes the correct envelope for an ActiveJob-shaped payload' do
      expect(client).to receive(:send_json).with(
        type: 'resque_job',
        metric: 'perform_duration',
        value: 0.42,
        custom_labels: { job_class: 'MyJob' }
      )

      described_class.record_perform_duration(payload_for(active_job_payload), 0.42)
    end

    it 'labels with the raw Resque payload class for vanilla Resque jobs' do
      payload = { 'class' => 'RawResqueJob', 'args' => [12345, 'some_string'] }

      expect(client).to receive(:send_json).with(
        hash_including(custom_labels: { job_class: 'RawResqueJob' })
      )

      described_class.record_perform_duration(payload_for(payload), 0.5)
    end

    context 'when client.send_json raises' do
      it 'rescues the error and logs a warning' do
        allow(client).to receive(:send_json).and_raise(StandardError, 'boom')
        expect(Bigcommerce::Prometheus.logger).to receive(:warn).with(/perform_duration push failed: boom/)

        expect do
          described_class.record_perform_duration(payload_for(active_job_payload), 0.1)
        end.not_to raise_error
      end
    end
  end
end
