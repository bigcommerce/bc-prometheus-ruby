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

describe Bigcommerce::Prometheus::Integrations::Resque do
  let(:fork_reset) { Bigcommerce::Prometheus::Integrations::Resque::ForkReset }
  let(:logger) { instance_double(Logger, warn: nil, info: nil) }

  let(:worker_class) { Class.new }

  before do
    allow(Bigcommerce::Prometheus).to receive(:logger).and_return(logger)
    allow(worker_class).to receive(:prepend)
    stub_const('Resque::Worker', worker_class)
    allow(::PrometheusExporter::Instrumentation::Process).to receive(:start)
    allow(Bigcommerce::Prometheus::Collectors::Resque).to receive(:start)
    allow(Bigcommerce::Prometheus::Integrations::Resque::JobMetrics).to receive(:start)
  end

  around do |example|
    original_client = Bigcommerce::Prometheus::Integrations::Resque::ForkReset.client
    original_pid = Bigcommerce::Prometheus::Integrations::Resque::ForkReset.installed_in_pid
    example.run
    Bigcommerce::Prometheus::Integrations::Resque::ForkReset.client = original_client
    Bigcommerce::Prometheus::Integrations::Resque::ForkReset.installed_in_pid = original_pid
  end

  describe 'with a client that can reset itself' do
    let(:client) { instance_double(Bigcommerce::Prometheus::Client, reset_after_fork!: nil) }

    it 'wraps the worker, so a child is reset before its after_fork hooks run' do
      described_class.start(client: client)

      expect(worker_class).to have_received(:prepend).with(fork_reset)
    end

    it 'records the installing pid, which is what a child compares itself against' do
      described_class.start(client: client)

      expect(fork_reset.installed_in_pid).to eq Process.pid
    end
  end

  describe 'with a client that cannot reset itself' do
    let(:client) { instance_double(PrometheusExporter::Client) }

    before { fork_reset.installed_in_pid = nil }

    it 'says so at boot, which is the only signal the caller gets' do
      described_class.start(client: client)

      expect(logger).to have_received(:warn).with(/resque fork reset skipped/)
    end

    it 'does not wrap the worker with a reset that cannot run' do
      described_class.start(client: client)

      expect(worker_class).not_to have_received(:prepend)
    end

    it 'records no pid, so nothing later reads the wrapper as installed' do
      described_class.start(client: client)

      expect(fork_reset.installed_in_pid).to be_nil
    end
  end
end
