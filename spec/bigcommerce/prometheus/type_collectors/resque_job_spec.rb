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

describe Bigcommerce::Prometheus::TypeCollectors::ResqueJob do
  let(:type_collector) { described_class.new }

  # The registered type is the production-routing contract:
  # PrometheusExporter::Server::Collector keys @collectors by collector.type
  # and dispatches each envelope by envelope['type']. JobMetrics.record_*
  # hardcodes envelopes with type: 'resque_job', so this collector must
  # register under the same string for the router to find it. Asserting it
  # here keeps the contract from drifting silently (e.g. someone removing the
  # explicit type: argument and falling back to the gsub auto-derivation).
  describe '#type' do
    it 'returns "resque_job" so the upstream router can dispatch resque_job envelopes' do
      expect(type_collector.type).to eq('resque_job')
    end
  end

  describe '#build_metrics' do
    subject { type_collector.build_metrics }

    it 'returns a hash of prometheus metric objects' do
      expect(subject).to be_a(Hash)
      expect(subject.count).to eq 2
    end

    {
      queue_latency: {
        name: 'resque_job_queue_latency_seconds',
        class: PrometheusExporter::Metric::Histogram
      },
      perform_duration: {
        name: 'resque_job_perform_duration_seconds',
        class: PrometheusExporter::Metric::Histogram
      }
    }.each do |hash_key, config|
      it "builds the #{hash_key} with the expected class and name" do
        metric = subject[hash_key]
        expect(metric).to be_a config[:class]
        expect(metric.name).to eq config[:name]
      end
    end
  end

  # Exercise the public #collect entry point (defined on
  # TypeCollectors::Base) so the spec catches any label-handling bugs in the
  # Base → subclass dispatch — e.g. custom_labels getting merged twice.
  describe '#collect' do
    subject { type_collector.collect(data) }

    let(:type_collector) { described_class.new(default_labels: default_labels) }
    let(:default_labels) { { environment: 'development' } }

    context 'with a queue_latency payload' do
      let(:data) do
        {
          'type' => 'resque_job',
          'metric' => 'queue_latency',
          'value' => 1.5,
          'custom_labels' => { 'job_class' => 'MyJob' }
        }
      end

      # Base#collect merges data['custom_labels'] into labels once. The
      # subclass must not re-merge — observing with the labels as-is is the
      # correct behaviour. If a future refactor reintroduces a second merge,
      # this assertion fails because the observed label hash would also
      # include a duplicated/symbolised key.
      it 'observes the queue_latency histogram with custom_labels merged exactly once' do
        metrics = type_collector.instance_variable_get(:@metrics)

        expect(metrics[:queue_latency]).to receive(:observe).with(1.5, default_labels.merge('job_class' => 'MyJob'))
        expect(metrics[:perform_duration]).not_to receive(:observe)

        subject
      end
    end

    context 'with a perform_duration payload' do
      let(:data) do
        {
          'type' => 'resque_job',
          'metric' => 'perform_duration',
          'value' => 0.25,
          'custom_labels' => { 'job_class' => 'MyJob', 'event_name' => 'foo' }
        }
      end

      it 'observes the perform_duration histogram with custom_labels merged exactly once' do
        metrics = type_collector.instance_variable_get(:@metrics)

        expect(metrics[:perform_duration]).to receive(:observe).with(0.25, default_labels.merge('job_class' => 'MyJob', 'event_name' => 'foo'))
        expect(metrics[:queue_latency]).not_to receive(:observe)

        subject
      end
    end

    context 'with a payload with an unrecognised metric name' do
      let(:data) do
        {
          'type' => 'resque_job',
          'metric' => 'mystery',
          'value' => 0.25,
          'custom_labels' => {}
        }
      end

      it 'is a no-op' do
        metrics = type_collector.instance_variable_get(:@metrics)

        expect(metrics[:queue_latency]).not_to receive(:observe)
        expect(metrics[:perform_duration]).not_to receive(:observe)

        subject
      end
    end
  end
end
