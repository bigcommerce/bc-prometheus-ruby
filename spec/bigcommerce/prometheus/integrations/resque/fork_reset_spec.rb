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
describe Bigcommerce::Prometheus::Integrations::Resque::ForkReset do
  let(:client) { instance_double(Bigcommerce::Prometheus::Client, reset_after_fork!: nil) }
  let(:events) { [] }

  # Stands in for Resque::Worker, which is not loaded here. Its `perform` records the two things it does in the real
  # one, in the order it does them: the after_fork hooks at worker.rb:345, then the job body at worker.rb:347.
  let(:worker_class) do
    recorder = events
    klass = Class.new do
      define_method(:perform) do |_job, &_block|
        recorder << :after_fork_hooks
        recorder << :job
        :performed
      end
    end
    klass.prepend(described_class)
    klass
  end

  let(:worker) { worker_class.new }
  let(:job) { double('Resque::Job') }

  around do |example|
    original_client = described_class.client
    original_pid = described_class.installed_in_pid
    example.run
    described_class.client = original_client
    described_class.installed_in_pid = original_pid
  end

  before { described_class.client = client }

  context 'when running in a forked child' do
    # Any pid but this process's own. Forking for real is what spec/integration/resque_fork_delivery_spec.rb is for;
    # here the changed pid is the whole condition under test, so it is set directly.
    before { described_class.installed_in_pid = Process.pid + 1 }

    it 'discards the queue the child inherited from its parent' do
      worker.perform(job)

      expect(client).to have_received(:reset_after_fork!)
    end

    # The reason this is a prepend rather than a Resque.after_fork hook. Hooks run in registration order, so one
    # registered before this integration started would push an observation into the queue that is about to be thrown
    # away.
    it 'discards it before the after_fork hooks run, so nothing they record is thrown away' do
      allow(client).to receive(:reset_after_fork!) { events << :reset }

      worker.perform(job)

      expect(events).to eq %i[reset after_fork_hooks job]
    end

    it 'still runs the job' do
      expect(worker.perform(job)).to eq :performed
    end
  end

  context 'when running in the process that installed it' do
    before { described_class.installed_in_pid = Process.pid }

    # `Worker#perform` runs in the long-lived parent for a FORK_PER_JOB=false worker and via the deprecated
    # `Worker#process`. Resetting there would throw away messages nobody else is going to send.
    it 'leaves the queue alone, since the parent is still responsible for sending it' do
      worker.perform(job)

      expect(client).not_to have_received(:reset_after_fork!)
    end

    it 'still runs the job' do
      expect(worker.perform(job)).to eq :performed
    end
  end

  context 'when no pid was recorded' do
    before { described_class.installed_in_pid = nil }

    it 'leaves the queue alone, since there is nothing to say this is a child' do
      worker.perform(job)

      expect(client).not_to have_received(:reset_after_fork!)
    end
  end

  context 'when the client cannot reset itself' do
    let(:client) { instance_double(PrometheusExporter::Client) }

    before { described_class.installed_in_pid = Process.pid + 1 }

    # A caller may hand `Integrations::Resque.start` a plain upstream client, which has no `reset_after_fork!`. That
    # costs the child the clean queue, but it must not cost it the job.
    it 'does nothing rather than raising' do
      expect { worker.perform(job) }.not_to raise_error
    end
  end
end
