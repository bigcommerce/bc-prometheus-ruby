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
require 'benchmark'
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
# Black box: N jobs run, N observations arrive, and instrumentation does not blow out job time.
#
# Deliberately says nothing about queues, threads or forks. Both properties have been broken by past changes from
# opposite directions. PAYMENTS-11567 met completeness by adding 480ms per job. PAYMENTS-11727 kept job time flat by
# silently dropping the metrics. A change that satisfies one at the expense of the other should fail here.
#
# Forks real children and needs a redis, so it is excluded from the default run. To run it:
#
#   FORK_INTEGRATION=1 REDIS_URL=redis://127.0.0.1:6379/15 bundle exec rspec spec/integration
#
describe 'metric delivery from Resque forked children', :fork_integration do
  JOB_COUNT = 100

  # Per-job overhead the instrumentation is allowed to add, measured against an identical run with metrics off so the
  # machine's own speed cancels out.
  #
  # Measured cost is 0.90ms per job, against 2.5ms for the same jobs with metrics disabled, so the budget sits about
  # 27x above what this should take and about 19x below the 480ms regression it exists to catch. Wide on both sides,
  # because a latency assertion on CI hardware has to be.
  OVERHEAD_BUDGET_SECONDS = 0.025

  let(:exporter) { CountingExporter.new.start }
  let(:queue) { ForkDeliveryProbeJob.instance_variable_get(:@queue) }

  before do
    skip "redis unavailable at #{redis_url}" unless redis_available?

    Resque.redis = Redis.new(url: redis_url)
    Resque.redis.redis.flushdb
    Resque.logger = Logger.new(File::NULL)

    Bigcommerce::Prometheus.configure do |config|
      config.enabled = true
      config.logger = Logger.new(File::NULL)
      config.server_host = '127.0.0.1'
      config.server_port = exporter.port
    end

    # The client is a singleton that captures host and port when it is first built, which earlier specs in the run may
    # already have done. Point the existing instance at this run's exporter and drop anything they left queued, so the
    # result does not depend on spec ordering.
    client = Bigcommerce::Prometheus.client
    client.instance_variable_set(:@host, '127.0.0.1')
    client.instance_variable_set(:@port, exporter.port)
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

  # Drains the queue synchronously, one job at a time, so the run has no timers or sleeps in it. Each call still forks,
  # runs the after_fork hooks and exits the child exactly as a live worker does.
  #
  # @param [Integer] count
  # @return [Float] seconds elapsed
  def run_jobs(count)
    count.times { Resque::Job.create(queue, ForkDeliveryProbeJob, 'n' => 1) }
    worker = Resque::Worker.new(queue)
    Benchmark.realtime { count.times { worker.work_one_job } }
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
