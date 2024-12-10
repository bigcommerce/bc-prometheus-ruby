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

describe Bigcommerce::Prometheus::Servers::Puma::Controllers::SendMetricsController do
  let(:request_method) { 'POST' }
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
  let(:server_metrics) { Bigcommerce::Prometheus::Servers::Puma::ServerMetrics.new }
  let(:controller) { described_class.new(request: request, response: response, server_metrics: server_metrics, collector: collector, logger: logger) }

  describe '#call' do
    subject { controller.call }

    context 'when a post request' do
      context 'when the collector properly parses the metrics' do
        before do
          expect(collector).to receive(:process).once
        end

        it 'succeeds' do
          expect(subject.status).to eq 200
          expect(subject.body.first).to eq 'OK'
        end
      end

      context 'when the collector fails to parse the metrics' do
        let(:error_message) { 'failure!' }
        let(:exception) { StandardError.new(error_message) }
        before do
          expect(collector).to receive(:process).once.and_raise(exception)
        end

        it 'fails' do
          expect(subject.status).to eq 500
          parsed_body = JSON.parse(subject.body.first)
          expect(parsed_body).to eq [error_message]
        end
      end
    end

    context 'when not a post request' do
      let(:request_method) { 'GET' }

      it 'fails' do
        expect(subject.status).to eq 500
        parsed_body = JSON.parse(subject.body.first)
        expect(parsed_body).to eq ['Invalid request type. Only POST is supported.']
      end
    end
  end
end
