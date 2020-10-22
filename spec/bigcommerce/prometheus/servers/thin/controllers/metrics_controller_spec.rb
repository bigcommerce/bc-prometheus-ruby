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

describe Bigcommerce::Prometheus::Servers::Thin::Controllers::MetricsController do
  let(:request_method) { 'GET' }
  let(:env) do
    {
      'REQUEST_METHOD' => request_method,
      'rack.input' => StringIO.new(body),
    }
  end
  let(:body) { '' }
  let(:request) { Rack::Request.new(env) }
  let(:response) { Rack::Response.new }
  let(:collector) { PrometheusExporter::Server::Collector.new }
  let(:server_metrics) { Bigcommerce::Prometheus::Servers::Thin::ServerMetrics.new }
  let(:controller) { described_class.new(request: request, response: response, server_metrics: server_metrics, collector: collector, logger: logger) }

  let(:metrics) { ['ruby_collector_metrics_total 19', 'ruby_collector_sessions_total 19'].join("\n") }
  let(:server_metrics_text) { ['collector_working 1', 'collector_rss 60440'].join("\n") }

  before do
    allow(collector).to receive(:prometheus_metrics_text).and_return(metrics)
    allow(server_metrics).to receive(:to_prometheus_text).and_return(server_metrics_text)
  end

  describe '#call' do
    subject { controller.call }

    it 'succeeds' do
      expect(subject.status).to eq 200
      expect(subject.body.first).to eq 'collector_working 1
collector_rss 60440
ruby_collector_metrics_total 19
ruby_collector_sessions_total 19'
    end

    context 'when the metrics fail to parse' do
      let(:timeout_exception) { ::Timeout::Error }
      before do
        allow(collector).to receive(:prometheus_metrics_text).and_raise(timeout_exception)
      end

      it 'still responds 200, but logs an error' do
        expect(logger).to receive(:error).with('Generating Prometheus metrics text timed out')
        expect(subject.status).to eq 200
        expect(subject.body.first).to eq 'collector_working 1
collector_rss 60440
'
      end
    end
  end
end
