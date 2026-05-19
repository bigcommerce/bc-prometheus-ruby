# frozen_string_literal: true

require 'spec_helper'

describe Bigcommerce::Prometheus::TypeCollectors::ActiveRecordSql do
  let(:type_collector) { described_class.new }

  describe '#type' do
    it 'is "active_record_sql" so pushes from the integration are routed here' do
      expect(type_collector.type).to eq 'active_record_sql'
    end
  end

  describe '#build_metrics' do
    subject { type_collector.build_metrics }

    it 'registers sql_query_duration_seconds as a Histogram' do
      metric = subject[:sql_query_duration_seconds]
      expect(metric).to be_a PrometheusExporter::Metric::Histogram
      expect(metric.name).to eq 'sql_query_duration_seconds'
    end

    it 'includes long-running query buckets' do
      metric = subject[:sql_query_duration_seconds]
      expect(metric.instance_variable_get(:@buckets)).to include(20, 30, 60)
    end
  end

  describe '#collect_metrics' do
    let(:metrics) { type_collector.instance_variable_get(:@metrics) }

    it 'observes the duration with the operation label' do
      expect(metrics[:sql_query_duration_seconds]).to receive(:observe).with(0.025, { operation: 'select' })
      type_collector.collect_metrics(
        data: { 'duration_seconds' => 0.025 },
        labels: { operation: 'select' }
      )
    end

    it 'is a no-op when duration_seconds is missing' do
      expect(metrics[:sql_query_duration_seconds]).not_to receive(:observe)
      type_collector.collect_metrics(data: {}, labels: { operation: 'select' })
    end
  end
end
