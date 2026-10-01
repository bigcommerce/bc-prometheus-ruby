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
# Pushes a metric as its final statement, with no work after it.
# This is the worst case as the Resque exits immediately after the metric is queued.
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
# Pushes several observations as its final statement, so the default flush budget has more than one
# message to deliver before the child exits.
#
class ForkDeliveryMultiProbeJob
  METRIC_NAME = 'fork_delivery_multi_probe_counter'
  OBSERVATIONS_PER_JOB = 5
  @queue = :bc_prometheus_fork_delivery_multi

  def self.perform(_payload)
    OBSERVATIONS_PER_JOB.times do
      Bigcommerce::Prometheus.client.send_json(
        type: 'fork_delivery_multi_probe',
        name: METRIC_NAME,
        value: 1.0
      )
    end
  end
end

#
# Black box: runs N jobs, then asserts that N observations arrive and that the instrumentation stays within the
# per-job overhead budget.
#
# To run it:
#   REDIS_URL=redis://127.0.0.1:6379/15 bundle exec rspec --tag fork_integration spec/integration
#
describe 'metric delivery from Resque forked children', :fork_integration do
  JOB_COUNT = 100

  OVERHEAD_BUDGET_SECONDS = 0.05

  let(:exporter) { CountingExporter.new.start }
  let(:queue) { ForkDeliveryProbeJob.instance_variable_get(:@queue) }

  before do
    raise "redis unavailable at #{redis_url}; the fork integration specs need one" unless redis_available?

    Resque.redis = Redis.new(url: redis_url)
    Resque.redis.redis.flushdb
    Resque.logger = Logger.new(File::NULL)

    Bigcommerce::Prometheus.configure do |config|
      config.enabled = true
      config.logger = Logger.new(File::NULL)
      config.server_host = '127.0.0.1'
      config.server_port = exporter.port
      config.client_flush_timeout = 5.0
    end

    client = Bigcommerce::Prometheus.client
    client.instance_variable_get(:@worker_thread)&.kill
    client.instance_variable_set(:@host, '127.0.0.1')
    client.instance_variable_set(:@port, exporter.port)
    client.reset_after_fork!
  end

  after { exporter.stop }

  describe 'completeness' do
    before do
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
      Bigcommerce::Prometheus::Integrations::Resque.start(client: Bigcommerce::Prometheus.client)
    end

    it 'delivers one observation for every job that pushed one' do
      run_jobs(JOB_COUNT)

      expect(exporter.count_for(ForkDeliveryProbeJob::METRIC_NAME)).to eq JOB_COUNT
    end
  end

  # The other examples in this file set a generous PROMETHEUS_CLIENT_FLUSH_TIMEOUT on purpose, to isolate what
  # each of them is actually testing from timing noise. This example instead checks whether the
  # default leaves enough time to deliver the metrics for a job that records more than one.
  describe 'completeness at the default flush timeout' do
    let(:default_client_flush_timeout) { Bigcommerce::Prometheus::Configuration::VALID_CONFIG_KEYS[:client_flush_timeout] }
    let(:queue) { ForkDeliveryMultiProbeJob.instance_variable_get(:@queue) }

    JOB_COUNT_AT_DEFAULT_TIMEOUT = 10

    before do
      Bigcommerce::Prometheus.client_flush_timeout = default_client_flush_timeout
      Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
      Bigcommerce::Prometheus::Integrations::Resque.start(client: Bigcommerce::Prometheus.client)
    end

    it 'delivers every observation from every job, not just one per job' do
      count = JOB_COUNT_AT_DEFAULT_TIMEOUT
      count.times { Resque::Job.create(queue, ForkDeliveryMultiProbeJob, 'n' => 1) }
      worker = Resque::Worker.new(queue)
      count.times { worker.work_one_job }

      expected = count * ForkDeliveryMultiProbeJob::OBSERVATIONS_PER_JOB
      expect(exporter.count_for(ForkDeliveryMultiProbeJob::METRIC_NAME)).to eq expected
    end
  end

  describe 'overhead' do
    it 'adds less than the per-job budget over an identical run without the flush wrapper installed' do
      expect(measured_overhead_per_job).to be < OVERHEAD_BUDGET_SECONDS
    end
  end

  ##
  # @param [Integer] count
  # @return [Float] seconds elapsed
  #
  def run_jobs(count)
    count.times { Resque::Job.create(queue, ForkDeliveryProbeJob, 'n' => 1) }
    worker = Resque::Worker.new(queue)

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    count.times { worker.work_one_job }
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  end

  ##
  # @return [Float] seconds of instrumentation cost per job
  #
  def measured_overhead_per_job
    Bigcommerce::Prometheus.resque_flush_on_exit_enabled = false
    Bigcommerce::Prometheus::Integrations::Resque.start(client: Bigcommerce::Prometheus.client)
    without_flush = run_jobs(JOB_COUNT)

    Bigcommerce::Prometheus.resque_flush_on_exit_enabled = true
    Bigcommerce::Prometheus::Integrations::Resque.start(client: Bigcommerce::Prometheus.client)
    with_flush = run_jobs(JOB_COUNT)

    (with_flush - without_flush) / JOB_COUNT
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
