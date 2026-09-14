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
require 'resque'

##
# Pushes a metric as the final statement of the job, with nothing after it.
#
# This is the worst case and the shape that broke in production: once the push returns there is no further work, so
# Resque's `exit!` follows immediately and anything relying on the background delivery thread is lost.
#
class ForkDeliveryProbeJob
  METRIC_NAME = 'fork_delivery_probe_counter'
  @queue = :bc_prometheus_fork_delivery

  def self.perform(_payload)
    Bigcommerce::Prometheus.client.send_json(
      type: 'fork_delivery_probe',
      name: METRIC_NAME,
      value: 1.0
    )
  end
end

##
# Black box: runs N jobs, then asserts that N observations arrive and that instrumentation stays within the per-job
# overhead budget.
#
# Forks real children and needs a redis.
# To run it:
#   FORK_INTEGRATION=1 REDIS_URL=redis://127.0.0.1:6379/15 bundle exec rspec spec/integration
#
describe 'metric delivery from Resque forked children', :fork_integration do
  JOB_COUNT = 100

  # Per-job overhead the instrumentation is allowed to add, measured against an identical run with metrics off so the
  # machine's own speed cancels out.
  #
  # Measured cost is 0.90ms per job.
  # The budget sits about 27x above that and about 19x below the 480ms regression it
  # exists to catch, wide on both sides because a latency assertion on CI hardware has to be.
  OVERHEAD_BUDGET_SECONDS = 0.025

  let(:exporter) { CountingExporter.new.start }
  let(:queue) { ForkDeliveryProbeJob.instance_variable_get(:@queue) }

  before do
    # Raise rather than skip.
    # The tag filter means this hook only runs when someone asked for these specs, so a missing redis is a broken
    # request rather than an absent option.
    raise "redis unavailable at #{redis_url}; the fork integration specs need one" unless redis_available?

    Resque.redis = Redis.new(url: redis_url)
    Resque.redis.redis.flushdb
    Resque.logger = Logger.new(File::NULL)

    Bigcommerce::Prometheus.configure do |config|
      config.enabled = true
      config.logger = Logger.new(File::NULL)
      config.server_host = '127.0.0.1'
      config.server_port = exporter.port
      # Opt in explicitly
      config.resque_flush_on_exit_enabled = true
      # The `completeness` example below asserts that an observation arrives for every job, with none missing.
      # The timeout is deliberately set far above the 20ms production default, so that a loaded CI runner exceeding
      # that default does not drop observations.
      config.client_flush_timeout = 5.0
    end

    # `Bigcommerce::Prometheus.client` is a `Singleton`, so this run cannot get a fresh one.
    # It captured its host and port when first built, which an earlier spec in the run may already have done.
    # Reconfiguring that instance and dropping whatever it has queued keeps the result independent of spec ordering.
    client = Bigcommerce::Prometheus.client

    # `reset_after_fork!` drops the reference to the delivery thread rather than stopping it, which is right in a
    # forked child, where that thread did not survive the fork and there is nothing to stop.
    # Calling it in this process leaves the old thread running, and its loop reads `@delivery` fresh on every pass,
    # so an orphan keeps draining whatever queue the client holds now.
    # Stopping it first is what keeps one example from sending another example's metrics.
    client.instance_variable_get(:@worker_thread)&.kill
    client.instance_variable_set(:@host, '127.0.0.1')
    client.instance_variable_set(:@port, exporter.port)
    client.instance_variable_set(:@flush_timeout, 5.0)
    client.reset_after_fork!

    Bigcommerce::Prometheus::Integrations::Resque.start(client: client)
  end

  after { exporter.stop }

  describe 'completeness' do
    it 'delivers one observation for every job that pushed one' do
      run_jobs(JOB_COUNT)

      expect(exporter.count_for(ForkDeliveryProbeJob::METRIC_NAME)).to eq JOB_COUNT
    end
  end

  describe 'overhead' do
    it 'adds less than the per-job budget over an identical run with metrics disabled' do
      expect(measured_overhead_per_job).to be < OVERHEAD_BUDGET_SECONDS
    end
  end

  # --- helpers -----------------------------------------------------------

  # Drains the queue by calling `work_one_job` directly rather than `Worker#work`, whose poll loop sleeps for its
  # interval whenever `reserve` finds nothing.
  # Those sleeps would be counted in the elapsed time below and swamp the sub-millisecond per-job cost being measured.
  # Each call still forks, runs the after_fork hooks and exits the child exactly as a live worker does.
  #
  # @param [Integer] count
  # @return [Float] seconds elapsed
  def run_jobs(count)
    count.times { Resque::Job.create(queue, ForkDeliveryProbeJob, 'n' => 1) }
    worker = Resque::Worker.new(queue)

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    count.times { worker.work_one_job }
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  end

  # @return [Float] seconds of instrumentation cost per job
  def measured_overhead_per_job
    Bigcommerce::Prometheus.enabled = false
    without_metrics = run_jobs(JOB_COUNT)

    Bigcommerce::Prometheus.enabled = true
    with_metrics = run_jobs(JOB_COUNT)

    (with_metrics - without_metrics) / JOB_COUNT
  end

  def redis_url
    ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379/15')
  end

  def redis_available?
    Redis.new(url: redis_url, timeout: 0.5).ping
    true
  rescue StandardError
    false
  end
end
