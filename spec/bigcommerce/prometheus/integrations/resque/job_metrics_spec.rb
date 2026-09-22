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
require 'resque'

describe Bigcommerce::Prometheus::Integrations::Resque::JobMetrics do
  let(:client) { instance_double(PrometheusExporter::Client, send_json: nil) }
  let(:queue_name) { 'default' }

  before do
    # Inject the client directly so each example exercises the record_* logic
    # without the .start gating. The production code path is the same once
    # `@client` is set.
    described_class.instance_variable_set(:@client, client)
  end

  after do
    described_class.instance_variable_set(:@client, nil)
  end

  def resque_job(payload, queue = queue_name)
    Resque::Job.new(queue, payload)
  end

  # Build a real payload object from a payload hash. Both record_* methods
  # take the payload object the WorkerInstrumentation prepend builds once per
  # job via JobPayload.for and shares between the two recordings;
  # classification and parsing edge cases are covered in the payload specs.
  def payload_for(payload_hash)
    Bigcommerce::Prometheus::Integrations::Resque::JobPayload.for(resque_job(payload_hash))
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
        custom_labels: { job_class: 'MyJob', queue: queue_name }
      )

      described_class.record_queue_latency(payload_for(active_job_payload(enqueued_at: enqueued)), queue: queue_name)
    end

    it 'clamps the value to zero when the anchor is in the future (clock skew)' do
      future = (Time.now + 5).iso8601(6)

      expect(client).to receive(:send_json).with(
        hash_including(metric: 'queue_latency', value: 0.0)
      )

      described_class.record_queue_latency(payload_for(active_job_payload(enqueued_at: future)), queue: queue_name)
    end

    it 'is a no-op for a vanilla Resque payload (no anchor available, no exception)' do
      payload = { 'class' => 'RawResqueJob', 'args' => [12_345, 'some_string'] }

      expect(client).not_to receive(:send_json)

      expect do
        described_class.record_queue_latency(payload_for(payload), queue: queue_name)
      end.not_to raise_error
    end

    context 'when client.send_json raises' do
      it 'rescues the error and logs a warning' do
        allow(client).to receive(:send_json).and_raise(StandardError, 'boom')
        expect(Bigcommerce::Prometheus.logger).to receive(:warn).with(/queue_latency push failed: boom/)

        expect do
          described_class.record_queue_latency(
            payload_for(active_job_payload(enqueued_at: Time.now.iso8601(6))), queue: queue_name
          )
        end.not_to raise_error
      end
    end
  end

  describe '.record_perform_duration' do
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    it 'pushes the correct envelope for an ActiveJob-shaped payload' do
      expect(client).to receive(:send_json).with(
        type: 'resque_job',
        metric: 'perform_duration',
        value: a_value_within(0.05).of(0.42),
        custom_labels: { job_class: 'MyJob', queue: queue_name }
      )

      described_class.record_perform_duration(payload_for(active_job_payload), monotonic_now - 0.42, queue: queue_name)
    end

    it 'labels with the raw Resque payload class for vanilla Resque jobs' do
      payload = { 'class' => 'RawResqueJob', 'args' => [12_345, 'some_string'] }

      expect(client).to receive(:send_json).with(
        hash_including(custom_labels: { job_class: 'RawResqueJob', queue: queue_name })
      )

      described_class.record_perform_duration(payload_for(payload), monotonic_now, queue: queue_name)
    end

    it 'coerces a Symbol queue, so it cannot key a second histogram entry that renders identically' do
      expect(client).to receive(:send_json).with(
        hash_including(custom_labels: { job_class: 'MyJob', queue: 'scheduled_action' })
      )

      described_class.record_perform_duration(payload_for(active_job_payload), monotonic_now, queue: :scheduled_action)
    end

    it "falls back to 'unknown' when the queue is nil" do
      expect(client).to receive(:send_json).with(
        hash_including(custom_labels: { job_class: 'MyJob', queue: 'unknown' })
      )

      described_class.record_perform_duration(payload_for(active_job_payload), monotonic_now, queue: nil)
    end

    it "falls back to 'unknown' when the queue is blank" do
      expect(client).to receive(:send_json).with(
        hash_including(custom_labels: { job_class: 'MyJob', queue: 'unknown' })
      )

      described_class.record_perform_duration(payload_for(active_job_payload), monotonic_now, queue: '')
    end

    it 'rescues a nil started_at instead of raising into the caller ensure block' do
      expect do
        described_class.record_perform_duration(payload_for(active_job_payload), nil, queue: queue_name)
      end.not_to raise_error
    end

    context 'when client.send_json raises' do
      it 'rescues the error and logs a warning' do
        allow(client).to receive(:send_json).and_raise(StandardError, 'boom')
        expect(Bigcommerce::Prometheus.logger).to receive(:warn).with(/perform_duration push failed: boom/)

        expect do
          described_class.record_perform_duration(payload_for(active_job_payload), monotonic_now, queue: queue_name)
        end.not_to raise_error
      end
    end
  end

  describe 'WorkerInstrumentation#perform_with_fork' do
    let(:worker_class) do
      klass = Class.new do
        def perform_with_fork(_job, &_block)
          :performed
        end
      end
      klass.prepend(described_class::WorkerInstrumentation)
      klass
    end

    it 'records a measured perform duration around super' do
      worker_class.new.perform_with_fork(resque_job('class' => 'RawResqueJob', 'args' => []))

      expect(client).to have_received(:send_json).with(
        hash_including(metric: 'perform_duration', value: a_value_within(0.05).of(0.0),
                       custom_labels: { job_class: 'RawResqueJob', queue: queue_name })
      )
    end

    context 'when payload construction fails with a non-StandardError' do
      it 'propagates the original error instead of masking it from the ensure block' do
        allow(Bigcommerce::Prometheus::Integrations::Resque::JobPayload).to receive(:for).and_raise(NoMemoryError)

        expect do
          worker_class.new.perform_with_fork(resque_job({}))
        end.to raise_error(NoMemoryError)
      end
    end
  end

  describe '.start' do
    # .start involves prepending which can't be undone. We stub Worker with a throwaway
    # subclass instead so the changes don't affect later tests.
    let(:worker_class) { Class.new(::Resque::Worker) }

    before do
      stub_const('Resque::Worker', worker_class)
      described_class.instance_variable_set(:@hooks_installed, nil)
    end

    after do
      described_class.instance_variable_set(:@hooks_installed, nil)
    end

    context 'when the feature is disabled' do
      it 'does not prepend the instrumentation' do
        allow(Bigcommerce::Prometheus).to receive(:resque_per_job_metrics_enabled).and_return(false)

        described_class.start(client: client)

        expect(worker_class.ancestors).not_to include(described_class::WorkerInstrumentation)
      end
    end

    context 'when the feature is enabled' do
      before do
        allow(Bigcommerce::Prometheus).to receive(:resque_per_job_metrics_enabled).and_return(true)
        allow(Bigcommerce::Prometheus.logger).to receive(:info)
      end

      it 'prepends WorkerInstrumentation onto Resque::Worker' do
        described_class.start(client: client)

        expect(worker_class.ancestors).to include(described_class::WorkerInstrumentation)
      end

      it 'installs the hooks only once across repeated starts' do
        allow(worker_class).to receive(:prepend).and_call_original

        described_class.start(client: client)
        described_class.start(client: client)

        expect(worker_class).to have_received(:prepend).once
      end

      it 'logs that the worker is being instrumented' do
        described_class.start(client: client)

        expect(Bigcommerce::Prometheus.logger).to have_received(:info).with(/instrumenting Resque::Worker/)
      end
    end

    context 'when the feature is enabled but the worker does not define perform_with_fork' do
      let(:worker_class) { Class.new }

      before do
        allow(Bigcommerce::Prometheus).to receive(:resque_per_job_metrics_enabled).and_return(true)
        allow(Bigcommerce::Prometheus.logger).to receive(:warn)
      end

      it 'warns that per-job metrics will not be recorded' do
        described_class.start(client: client)

        expect(Bigcommerce::Prometheus.logger).to have_received(:warn).with(/perform_with_fork is not defined/)
      end
    end

    context 'when the feature is enabled but FORK_PER_JOB is disabled' do
      before do
        allow(Bigcommerce::Prometheus).to receive(:resque_per_job_metrics_enabled).and_return(true)
        allow(Bigcommerce::Prometheus.logger).to receive(:warn)
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('FORK_PER_JOB').and_return('false')
      end

      it 'warns that only the forking path is instrumented' do
        described_class.start(client: client)

        expect(Bigcommerce::Prometheus.logger).to have_received(:warn).with(/not forking per job/)
      end
    end
  end
end
