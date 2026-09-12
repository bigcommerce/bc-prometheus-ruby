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

describe Bigcommerce::Prometheus::Integrations::Resque::FlushOnExitSetting do
  let(:job) { double('Resque::Job', queue: 'scheduled_action') }

  around do |example|
    original = Bigcommerce::Prometheus.resque_flush_on_exit_enabled
    example.run
    Bigcommerce::Prometheus.resque_flush_on_exit_enabled = original
  end

  describe '#possible?' do
    subject(:possible) { described_class.current.possible? }

    it 'is false when the setting is off, so nothing is installed' do
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = false
      expect(possible).to be false
    end

    it 'is true when the setting is on' do
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
      expect(possible).to be true
    end

    # The callable has not been asked anything yet. Refusing to install here would make a runtime decision
    # impossible, since there would be nothing left to ask it.
    it 'is true for a callable, even one that will answer false' do
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = -> { false }
      expect(possible).to be true
    end
  end

  describe '#dynamic?' do
    it 'is true only for a callable, which is what the install log reports' do
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = -> { true }
      expect(described_class.current).to be_dynamic
    end

    it 'is false for a plain value' do
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
      expect(described_class.current).not_to be_dynamic
    end
  end

  # Resolves whether the child about to be forked should flush. Runs in the parent, which is the whole point: a caller
  # can hand over a feature flag client without any of it reaching a forked child.
  describe '#resolve' do
    subject(:resolved) { described_class.current.resolve(job) }

    context 'when the setting is a plain value' do
      it 'is true when enabled' do
        Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
        expect(resolved).to be true
      end

      it 'is false when disabled' do
        Bigcommerce::Prometheus.resque_flush_on_exit_enabled = false
        expect(resolved).to be false
      end
    end

    context 'when the setting is callable' do
      it 'asks it, so the answer can change between forks without a restart' do
        answers = [true, false].each
        Bigcommerce::Prometheus.resque_flush_on_exit_enabled = -> { answers.next }

        expect(described_class.current.resolve(job)).to be true
        expect(described_class.current.resolve(job)).to be false
      end

      it 'coerces a truthy answer to a boolean' do
        Bigcommerce::Prometheus.resque_flush_on_exit_enabled = -> { 'yes' }
        expect(resolved).to be true
      end

      it 'passes the job when the callable takes one, so a caller can decide per job' do
        Bigcommerce::Prometheus.resque_flush_on_exit_enabled = ->(j) { j.queue == 'scheduled_action' }
        expect(resolved).to be true
      end

      it 'does not pass the job when the callable takes none' do
        Bigcommerce::Prometheus.resque_flush_on_exit_enabled = -> { true }
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
        Bigcommerce::Prometheus.resque_flush_on_exit_enabled = checker

        expect(resolved).to be true
      end
    end

    context 'when the callable raises' do
      let(:logger) { instance_double(Logger, warn: nil) }

      before do
        allow(Bigcommerce::Prometheus).to receive(:logger).and_return(logger)
        Bigcommerce::Prometheus.resque_flush_on_exit_enabled = -> { raise 'flag service unreachable' }
      end

      # This runs as a before_fork hook, so anything escaping here propagates into perform_with_fork and stops the
      # worker processing jobs. A flaky feature flag must never be able to do that.
      it 'does not propagate, since a metrics decision must not stop a worker' do
        expect { resolved }.not_to raise_error
      end

      it 'falls back to not flushing, which is the behavior callers had before this existed' do
        expect(resolved).to be false
      end

      it 'says why, so a silently disabled flush is diagnosable' do
        resolved
        expect(logger).to have_received(:warn).with(/flush on exit check failed/)
      end
    end
  end
end
