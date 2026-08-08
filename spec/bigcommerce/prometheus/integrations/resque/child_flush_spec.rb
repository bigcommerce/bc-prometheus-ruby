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

describe Bigcommerce::Prometheus::Integrations::Resque::ChildFlush do
  let(:client) { instance_double(Bigcommerce::Prometheus::Client, flush!: nil) }
  let(:singleton_client) { instance_double(Bigcommerce::Prometheus::Client, flush!: nil) }

  # Stands in for Resque::Worker, which is not loaded here. The prepend only needs `perform` to wrap and
  # `fork_per_job?` to consult, mirroring how job_metrics_spec covers WorkerInstrumentation.
  let(:worker_class) do
    klass = Class.new do
      attr_writer :fork_per_job, :raise_on_perform

      def perform(_job, &_block)
        raise 'job blew up' if @raise_on_perform

        :performed
      end

      def fork_per_job?
        @fork_per_job.nil? ? true : @fork_per_job
      end
    end
    klass.prepend(described_class)
    klass
  end

  let(:worker) { worker_class.new }
  let(:job) { double('Resque::Job') }

  before do
    @original_enabled = described_class.enabled
    @original_client = described_class.client
    described_class.client = client
  end

  after do
    described_class.enabled = @original_enabled
    described_class.client = @original_client
  end

  context 'when the parent enabled it for this fork' do
    before { described_class.enabled = true }

    it 'delivers what the job recorded before the child exits' do
      worker.perform(job)
      expect(client).to have_received(:flush!)
    end

    it 'still runs the job' do
      expect(worker.perform(job)).to eq :performed
    end

    it 'delivers even when the job raises, since whatever it recorded before failing is still worth having' do
      worker.raise_on_perform = true

      expect { worker.perform(job) }.to raise_error('job blew up')
      expect(client).to have_received(:flush!)
    end

    # The queue drained has to be the one ForkReset cleared. Reaching for the singleton instead would deliver a
    # different queue whenever a caller passed `client:` to `Integrations::Resque.start`, as the fork integration spec
    # and the bench both do.
    it 'delivers the configured client rather than the singleton' do
      allow(Bigcommerce::Prometheus).to receive(:client).and_return(singleton_client)

      worker.perform(job)

      expect(client).to have_received(:flush!)
      expect(singleton_client).not_to have_received(:flush!)
    end

    # A caller may hand `Integrations::Resque.start` a plain upstream client, which has no `flush!`. Raising from the
    # `ensure` that calls this would replace whatever the job was already raising.
    it 'does nothing rather than raising when the client cannot flush' do
      described_class.client = instance_double(PrometheusExporter::Client)

      expect { worker.perform(job) }.not_to raise_error
    end
  end

  context 'when the parent disabled it for this fork' do
    before { described_class.enabled = false }

    it 'delivers nothing, so a caller that has turned it off pays nothing' do
      worker.perform(job)
      expect(client).not_to have_received(:flush!)
    end
  end

  context 'when the worker does not fork per job' do
    before do
      described_class.enabled = true
      worker.fork_per_job = false
    end

    it 'leaves delivery to the background thread, since the process is long-lived' do
      worker.perform(job)
      expect(client).not_to have_received(:flush!)
    end
  end
end
