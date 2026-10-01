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

describe Bigcommerce::Prometheus::Integrations::Resque::FlushOnExit do
  let(:client) { instance_double(Bigcommerce::Prometheus::Client, flush!: nil) }
  let(:singleton_client) { instance_double(Bigcommerce::Prometheus::Client, flush!: nil) }

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
    @original_client = described_class.client
    described_class.client = client
  end

  after { described_class.client = @original_client }

  context 'when the worker forks per job' do
    it 'delivers what the job recorded before the child exits' do
      worker.perform(job)

      expect(client).to have_received(:flush!)
    end

    it 'still runs the job' do
      expect(worker.perform(job)).to eq :performed
    end

    it 'delivers even when the job raises' do
      worker.raise_on_perform = true

      expect { worker.perform(job) }.to raise_error('job blew up')
      expect(client).to have_received(:flush!)
    end

    it 'delivers the configured client rather than the singleton' do
      allow(Bigcommerce::Prometheus).to receive(:client).and_return(singleton_client)

      worker.perform(job)

      expect(client).to have_received(:flush!)
      expect(singleton_client).not_to have_received(:flush!)
    end

    it 'does not raise when the client cannot flush' do
      described_class.client = instance_double(PrometheusExporter::Client)

      expect { worker.perform(job) }.not_to raise_error
    end
  end

  context 'when the worker does not fork per job' do
    before { worker.fork_per_job = false }

    it 'leaves delivery to the background thread, since the process is long-lived' do
      worker.perform(job)

      expect(client).not_to have_received(:flush!)
    end
  end
end
