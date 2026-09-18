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

describe Bigcommerce::Prometheus::Integrations::Resque::FlushOnExitInstaller do
  let(:worker_class) { Class.new }
  let(:logger) { instance_double(Logger, warn: nil, info: nil) }

  around do |example|
    original = Bigcommerce::Prometheus.resque_flush_on_exit_enabled
    example.run
    Bigcommerce::Prometheus.resque_flush_on_exit_enabled = original
  end

  before { allow(Bigcommerce::Prometheus).to receive(:logger).and_return(logger) }

  describe 'when the flush is off' do
    let(:client) { instance_double(Bigcommerce::Prometheus::Client) }

    before do
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = false
      described_class.new(client: client).install
    end

    it 'logs that flush is disabled' do
      expect(logger).to have_received(:info).with(/resque flush on exit is disabled/)
    end
  end

  describe 'with a client that cannot flush' do
    let(:client) { instance_double(PrometheusExporter::Client) }

    before do
      allow(worker_class).to receive(:prepend)
      stub_const('Resque::Worker', worker_class)
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
    end

    it 'logs that it is disabled' do
      described_class.new(client: client).install

      expect(logger).to have_received(:warn).with(/resque flush on exit is enabled/)
    end

    it 'does not prepend a flush that cannot run' do
      described_class.new(client: client).install

      expect(worker_class).not_to have_received(:prepend)
    end

    it 'leaves itself uninstalled, so a later call with a usable client still works' do
      described_class.new(client: client).install
      described_class.new(client: instance_double(Bigcommerce::Prometheus::Client, flush!: nil)).install

      expect(worker_class).to have_received(:prepend)
    end
  end

  describe 'with a client that can flush' do
    let(:client) { instance_double(Bigcommerce::Prometheus::Client, flush!: nil) }

    before do
      allow(worker_class).to receive(:prepend)
      stub_const('Resque::Worker', worker_class)
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
      described_class.new(client: client).install
    end

    it 'prepends the flush to the worker' do
      expect(worker_class).to have_received(:prepend)
    end

    it 'logs that it is installed' do
      expect(logger).to have_received(:info).with(/resque flush on exit installed/)
    end
  end

  describe 'when it has already been installed' do
    let(:client) { instance_double(Bigcommerce::Prometheus::Client, flush!: nil) }
    let(:worker_class) do
      Class.new.tap { |klass| klass.prepend(Bigcommerce::Prometheus::Integrations::Resque::FlushOnExit) }
    end

    before do
      stub_const('Resque::Worker', worker_class)
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
    end

    it 'logs nothing a second time' do
      described_class.new(client: client).install

      expect(logger).not_to have_received(:info)
    end

    it 'updates the client to flush, even though the module is already installed' do
      new_client = instance_double(Bigcommerce::Prometheus::Client, flush!: nil)

      described_class.new(client: new_client).install

      expect(Bigcommerce::Prometheus::Integrations::Resque::FlushOnExit.client).to be new_client
    end
  end
end
