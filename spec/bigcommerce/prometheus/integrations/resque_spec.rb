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
  # Resolves whether the child about to be forked should flush. Runs in the parent, which is the whole point: a caller
  # can hand over a feature flag client without any of it reaching a forked child.
  describe '.resolve_fork_exit_flush' do
    subject(:resolved) { described_class.send(:resolve_fork_exit_flush, job) }

    let(:job) { double('Resque::Job', queue: 'scheduled_action') }

    around do |example|
      original = Bigcommerce::Prometheus.resque_fork_exit_flush_enabled
      example.run
      Bigcommerce::Prometheus.resque_fork_exit_flush_enabled = original
    end

    context 'when the setting is a plain value' do
      it 'is true when enabled' do
        Bigcommerce::Prometheus.resque_fork_exit_flush_enabled = true
        expect(resolved).to be true
      end

      it 'is false when disabled' do
        Bigcommerce::Prometheus.resque_fork_exit_flush_enabled = false
        expect(resolved).to be false
      end
    end

    context 'when the setting is callable' do
      it 'asks it, so the answer can change between forks without a restart' do
        answers = [true, false].each
        Bigcommerce::Prometheus.resque_fork_exit_flush_enabled = -> { answers.next }

        expect(described_class.send(:resolve_fork_exit_flush, job)).to be true
        expect(described_class.send(:resolve_fork_exit_flush, job)).to be false
      end

      it 'coerces a truthy answer to a boolean' do
        Bigcommerce::Prometheus.resque_fork_exit_flush_enabled = -> { 'yes' }
        expect(resolved).to be true
      end

      it 'passes the job when the callable takes one, so a caller can decide per job' do
        Bigcommerce::Prometheus.resque_fork_exit_flush_enabled = ->(j) { j.queue == 'scheduled_action' }
        expect(resolved).to be true
      end

      it 'does not pass the job when the callable takes none' do
        Bigcommerce::Prometheus.resque_fork_exit_flush_enabled = -> { true }
        expect { resolved }.not_to raise_error
      end

      # An object with a #call method is as ordinary a callable as a lambda, but it has no #arity, so asking for one
      # directly raises and the rescue below turns that into a silent "never flush".
      it 'accepts an object that responds to call rather than only procs' do
        checker = Class.new do
          def call(job)
            job.queue == 'scheduled_action'
          end
        end.new
        Bigcommerce::Prometheus.resque_fork_exit_flush_enabled = checker

        expect(resolved).to be true
      end
    end

    context 'when the callable raises' do
      let(:logger) { instance_double(Logger, warn: nil) }

      before do
        allow(Bigcommerce::Prometheus).to receive(:logger).and_return(logger)
        Bigcommerce::Prometheus.resque_fork_exit_flush_enabled = -> { raise 'flag service unreachable' }
      end

      # This runs as a before_fork hook, so anything escaping here propagates into perform_with_fork and stops the
      # worker processing jobs. A flaky feature flag must never be able to do that.
      it 'does not propagate, since a metrics decision must not stop a worker' do
        expect { resolved }.not_to raise_error
      end

      it 'falls back to not flushing, which is the behaviour callers had before this existed' do
        expect(resolved).to be false
      end

      it 'says why, so a silently disabled flush is diagnosable' do
        resolved
        expect(logger).to have_received(:warn).with(/fork exit flush check failed/)
      end
    end
  end

  describe '.install_fork_exit_flush when the flush is off' do
    let(:logger) { instance_double(Logger, info: nil) }
    let(:client) { instance_double(Bigcommerce::Prometheus::Client) }

    before do
      allow(Bigcommerce::Prometheus).to receive(:logger).and_return(logger)
      Bigcommerce::Prometheus.resque_fork_exit_flush_enabled = false
      described_class.instance_variable_set(:@fork_exit_flush_installed, nil)
      described_class.send(:install_fork_exit_flush, client)
    end

    after { described_class.instance_variable_set(:@fork_exit_flush_installed, nil) }

    it 'says the flush is off, since a metric that never arrives looks like one never recorded' do
      expect(logger).to have_received(:info).with(/fork exit flush is off/)
    end

    # The child starts a delivery thread on the first push, and upstream runs its loop once before sleeping. A job
    # that keeps working after pushing often does get its metric out. A flat "are not delivered" would be false for
    # those jobs. The bench measures 100 of 200 arriving on a job that pushes, works, then pushes again.
    it 'does not claim the observations are always lost, because that depends on the job' do
      expect(logger).to have_received(:info).with(/only delivered if the background thread runs/)
    end
  end

  describe '.install_fork_exit_flush with a client that cannot flush' do
    # `Integrations::Resque.start` accepts any client, so a plain `PrometheusExporter::Client` can reach here. It has
    # no `flush!`. The per-job path stays silent about that on purpose, which left this case with no signal at all.
    let(:logger) { instance_double(Logger, warn: nil, info: nil) }
    let(:client) { instance_double(PrometheusExporter::Client) }

    # Resque is not loaded here, so the constants the install touches are stubbed, as job_metrics_spec does.
    let(:worker_class) { Class.new }
    let(:resque_module) do
      Module.new do
        def self.before_fork(&block); end
      end
    end

    before do
      allow(Bigcommerce::Prometheus).to receive(:logger).and_return(logger)
      allow(worker_class).to receive(:prepend)
      stub_const('Resque', resque_module)
      stub_const('Resque::Worker', worker_class)
      Bigcommerce::Prometheus.resque_fork_exit_flush_enabled = true
      described_class.instance_variable_set(:@fork_exit_flush_installed, nil)
    end

    after { described_class.instance_variable_set(:@fork_exit_flush_installed, nil) }

    it 'says so at boot, which is the only place the caller is told' do
      described_class.send(:install_fork_exit_flush, client)
      expect(logger).to have_received(:warn).with(/does not support flush!/)
    end

    it 'does not wire up a flush that cannot run' do
      described_class.send(:install_fork_exit_flush, client)
      expect(worker_class).not_to have_received(:prepend)
    end

    it 'leaves itself uninstalled, so a later call with a usable client still works' do
      described_class.send(:install_fork_exit_flush, client)
      expect(described_class.instance_variable_get(:@fork_exit_flush_installed)).to be_nil
    end

    it 'installs normally when the client can flush' do
      described_class.send(:install_fork_exit_flush, instance_double(Bigcommerce::Prometheus::Client, flush!: nil))
      expect(worker_class).to have_received(:prepend)
    end
  end
end
