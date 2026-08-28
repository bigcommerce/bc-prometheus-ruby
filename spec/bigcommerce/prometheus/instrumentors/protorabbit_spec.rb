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

describe Bigcommerce::Prometheus::Instrumentors::Protorabbit do
  subject(:instrumentor) { described_class.new }

  let(:registered_type_collectors) { [] }
  let(:server) do
    instance_double(
      Bigcommerce::Prometheus::Server,
      add_type_collector: nil,
      start: nil
    )
  end

  before do
    allow(Bigcommerce::Prometheus::Server).to receive(:new).and_return(server)
    allow(server).to receive(:add_type_collector) { |tc| registered_type_collectors << tc }
  end

  describe '#start' do
    context 'when prometheus is disabled' do
      before { allow(Bigcommerce::Prometheus).to receive(:enabled).and_return(false) }

      it 'does not start the server' do
        instrumentor.start

        expect(server).not_to have_received(:start)
      end
    end

    context 'when prometheus is enabled' do
      let(:collector) { class_double(Bigcommerce::Prometheus::Collectors::Base, start: nil) }
      let(:type_collector) { instance_double(Bigcommerce::Prometheus::TypeCollectors::Base) }

      before do
        allow(Bigcommerce::Prometheus).to receive_messages(
          enabled: true,
          protorabbit_collectors: [collector],
          protorabbit_type_collectors: [type_collector]
        )

        instrumentor.start
      end

      it 'registers the ActiveRecordCollector' do
        expect(server).to have_received(:add_type_collector).with(instance_of(PrometheusExporter::Server::ActiveRecordCollector))
      end

      it 'registers the ActiveRecord SQL type collector' do
        expect(registered_type_collectors).to include(instance_of(Bigcommerce::Prometheus::TypeCollectors::ActiveRecordSql))
      end

      # Consumers rely on being able to override a built-in type collector by configuring one with
      # the same type, which only works if theirs is registered last
      it 'registers the configured type collector last' do
        expect(registered_type_collectors.last).to eq type_collector
      end

      it 'starts the server' do
        expect(server).to have_received(:start)
      end

      it 'starts the configured collector' do
        expect(collector).to have_received(:start)
      end
    end

    context 'when the server raises' do
      before do
        allow(Bigcommerce::Prometheus).to receive(:enabled).and_return(true)
        allow(server).to receive(:start).and_raise(StandardError, 'boom')
      end

      it 'rescues and logs the error instead of raising' do
        expect { instrumentor.start }.not_to raise_error
      end
    end
  end
end
