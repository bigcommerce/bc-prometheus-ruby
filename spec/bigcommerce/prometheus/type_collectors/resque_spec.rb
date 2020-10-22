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

describe Bigcommerce::Prometheus::TypeCollectors::Resque do
  let(:type_collector) { described_class.new }

  describe '#build_metrics' do
    subject { type_collector.build_metrics }

    it 'returns a hash of prometheus metric objects' do
      expect(subject).to be_a(Hash)
      expect(subject.count).to eq 6
    end

    {
      workers_total: {
        name: 'resque_workers_total',
        class: PrometheusExporter::Metric::Gauge,
        help: 'Number of active workers'
      },
      jobs_failed_total: {
        name: 'jobs_failed_total',
        class: PrometheusExporter::Metric::Gauge,
        help: 'Number of failed jobs'
      },
      jobs_pending_total: {
        name: 'jobs_pending_total',
        class: PrometheusExporter::Metric::Gauge,
        help: 'Number of pending jobs'
      },
      jobs_processed_total: {
        name: 'jobs_processed_total',
        class: PrometheusExporter::Metric::Gauge,
        help: 'Number of processed jobs'
      },
      queues_total: {
        name: 'queues_total',
        class: PrometheusExporter::Metric::Gauge,
        help: 'Number of total queues'
      },
      queue_sizes: {
        name: 'queue_sizes',
        class: PrometheusExporter::Metric::Gauge,
        help: 'Size of each queue'
      },

    }.each do |hash_key, config|
      it "builds the #{hash_key} with stat key of #{config[:key]}" do
        metric = subject[hash_key]
        expect(metric).to be_a config[:class]
        expect(metric.name).to eq config[:name]
        expect(metric.help).to eq config[:help]
      end
    end
  end

  describe '#collect_metrics' do
    subject { type_collector.collect_metrics(data: data, labels: labels) }

    let(:labels) { { environment: 'development' } }
    let(:data) do
      {
        'workers_total' => 10,
        'jobs_failed_total' => 123,
        'jobs_pending_total' => 5,
        'jobs_processed_total' => 10_000,
        'queues_total' => 6,
        'queues' => {
          'low' =>  1,
          'medium' => 2,
          'high' => 3
        }
      }
    end

    it 'properly logs metrics for all passed values' do
      metrics = type_collector.instance_variable_get(:@metrics)

      expect(metrics[:workers_total]).to receive(:observe).with(data['workers_total'], labels)
      expect(metrics[:jobs_failed_total]).to receive(:observe).with(data['jobs_failed_total'], labels)
      expect(metrics[:jobs_pending_total]).to receive(:observe).with(data['jobs_pending_total'], labels)
      expect(metrics[:jobs_processed_total]).to receive(:observe).with(data['jobs_processed_total'], labels)
      expect(metrics[:queues_total]).to receive(:observe).with(data['queues_total'], labels)

      expect(metrics[:queue_sizes]).to receive(:observe).ordered.with(data['queues']['low'], labels.merge(queue: 'low'))
      expect(metrics[:queue_sizes]).to receive(:observe).ordered.with(data['queues']['medium'], labels.merge(queue: 'medium'))
      expect(metrics[:queue_sizes]).to receive(:observe).ordered.with(data['queues']['high'], labels.merge(queue: 'high'))

      subject
    end
  end
end
