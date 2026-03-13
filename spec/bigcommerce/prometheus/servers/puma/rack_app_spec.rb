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

describe Bigcommerce::Prometheus::Servers::Puma::RackApp do
  let(:collector) { instance_double(PrometheusExporter::Server::Collector) }
  let(:server_metrics) { instance_double(Bigcommerce::Prometheus::Servers::Puma::ServerMetrics) }
  let(:app) { described_class.new(collector: collector, logger: logger) }

  before do
    allow(collector).to receive(:prometheus_metrics_text).and_return('')
    allow(server_metrics).to receive(:to_prometheus_text).and_return('')
    allow(Bigcommerce::Prometheus::Servers::Puma::ServerMetrics).to receive(:new).and_return(server_metrics)
  end

  describe '#call' do
    subject { app.call(env) }

    context 'when requesting GET /metrics' do
      let(:env) do
        {
          'REQUEST_METHOD' => 'GET',
          'PATH_INFO' => '/metrics',
          'QUERY_STRING' => '',
          'rack.input' => StringIO.new
        }
      end

      it 'returns content type of text/plain' do
        _status, headers, _body = subject
        expect(headers['Content-Type']).to eq('text/plain; charset=utf-8')
      end
    end
  end
end
