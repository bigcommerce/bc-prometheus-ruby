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
  around do |example|
    original = Bigcommerce::Prometheus.resque_flush_on_exit_enabled
    example.run
    Bigcommerce::Prometheus.resque_flush_on_exit_enabled = original
  end

  describe 'when the flush is off' do
    let(:logger) { instance_double(Logger, info: nil) }
    let(:client) { instance_double(Bigcommerce::Prometheus::Client) }

    before do
      allow(Bigcommerce::Prometheus).to receive(:logger).and_return(logger)
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = false
      described_class.new(client: client).install
    end

    it 'says the flush is disabled, since a metric that never arrives looks like one never recorded' do
      expect(logger).to have_received(:info).with(/resque flush on exit is disabled/)
    end
  end

  describe 'with a client that cannot flush' do
    # `Integrations::Resque.start` accepts any client, so a plain `PrometheusExporter::Client` can reach here. It has
    # no `flush!`. The per-job path stays silent about that on purpose, which left this case with no signal at all.
    let(:logger) { instance_double(Logger, warn: nil, info: nil) }
    let(:client) { instance_double(PrometheusExporter::Client) }

    # Resque is not loaded here, so the constant the install touches is stubbed, as job_metrics_spec does.
    let(:worker_class) { Class.new }

    before do
      allow(Bigcommerce::Prometheus).to receive(:logger).and_return(logger)
      allow(worker_class).to receive(:prepend)
      stub_const('Resque::Worker', worker_class)
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
    end

    it 'says so at boot, which is the only place the caller is told' do
      described_class.new(client: client).install
      expect(logger).to have_received(:warn).with(/resque flush on exit is enabled/)
    end

    it 'does not wire up a flush that cannot run' do
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
    let(:logger) { instance_double(Logger, warn: nil, info: nil) }
    let(:client) { instance_double(Bigcommerce::Prometheus::Client, flush!: nil) }

    # Resque is not loaded here, so the constant the install touches is stubbed, as job_metrics_spec does.
    let(:worker_class) { Class.new }

    before do
      allow(Bigcommerce::Prometheus).to receive(:logger).and_return(logger)
      allow(worker_class).to receive(:prepend)
      stub_const('Resque::Worker', worker_class)
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
      described_class.new(client: client).install
    end

    it 'wires the flush into the worker' do
      expect(worker_class).to have_received(:prepend)
    end

    it 'says so at boot, so the flush being active is visible in the log' do
      expect(logger).to have_received(:info).with(/resque flush on exit installed/)
    end
  end

  describe 'when it has already been installed' do
    let(:logger) { instance_double(Logger, warn: nil, info: nil) }
    let(:client) { instance_double(Bigcommerce::Prometheus::Client, flush!: nil) }
    let(:worker_class) do
      Class.new.tap { |klass| klass.prepend(Bigcommerce::Prometheus::Integrations::Resque::FlushOnExit) }
    end

    before do
      allow(Bigcommerce::Prometheus).to receive(:logger).and_return(logger)
      stub_const('Resque::Worker', worker_class)
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
    end

    # `prepend` is idempotent, so the chain would survive a second install either way. What the guard protects is the
    # boot log, and the client the first install chose.
    it 'says nothing a second time, so one boot logs one line' do
      described_class.new(client: client).install
      expect(logger).not_to have_received(:info)
    end

    it 'keeps the client the first install was given' do
      original = Bigcommerce::Prometheus::Integrations::Resque::FlushOnExit.client
      described_class.new(client: client).install

      expect(Bigcommerce::Prometheus::Integrations::Resque::FlushOnExit.client).to be original
    end
  end
end
