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

class ForkResetProbeJob
  METRIC_NAME = 'fork_reset_job_counter'
  WORK_SECONDS = 0.05
  @queue = :bc_prometheus_fork_reset

  def self.perform(_payload)
    Bigcommerce::Prometheus.client.send_json(
      type: 'fork_reset_probe',
      name: METRIC_NAME,
      value: 1.0
    )
    sleep WORK_SECONDS
  end
end

# Black box: proves a forked child does not send what the parent had queued.
#
# Forks real children and needs a redis.
# To run it:
#   REDIS_URL=redis://127.0.0.1:6379/15 bundle exec rspec --tag fork_integration spec/integration
#
describe 'a forked Resque child and the queue it inherits', :fork_integration do
  RESET_JOB_COUNT = 20
  BACKLOG_METRIC = 'fork_reset_parent_backlog'

  # Long enough that the parent's delivery thread sleeps through the whole run after its first pass.
  PARENT_THREAD_SLEEP = 30

  # Long enough for that first pass to finish before the first seed is queued.
  SETTLE_SECONDS = 0.2

  let(:exporter) { CountingExporter.new.start }
  let(:queue) { ForkResetProbeJob.instance_variable_get(:@queue) }
  let(:client) { Bigcommerce::Prometheus.client }
  let(:client_queue) { client.instance_variable_get(:@queue) }

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
    end

    client.instance_variable_get(:@worker_thread)&.kill
    client.instance_variable_set(:@host, '127.0.0.1')
    client.instance_variable_set(:@port, exporter.port)
    client.instance_variable_set(:@thread_sleep, PARENT_THREAD_SLEEP)
    client.reset_after_fork!

    Bigcommerce::Prometheus::Integrations::Resque.start(client: client)

    sleep SETTLE_SECONDS
  end

  after do
    exporter.stop
    Bigcommerce::Prometheus::Integrations::Resque::ForkReset.installed_in_pid = Process.pid
  end

  it 'sends nothing the parent had queued, so no observation is counted twice' do
    run_jobs(RESET_JOB_COUNT)

    expect(exporter.count_for(BACKLOG_METRIC)).to eq 0
  end

  it 'leaves the seeded backlog on the parent queue, which is what the children inherited a copy of' do
    run_jobs(RESET_JOB_COUNT)

    expect(queued_backlog_count).to eq RESET_JOB_COUNT
  end

  it 're-sends the parent backlog when the reset is inactive, which is the behavior being fixed' do
    Bigcommerce::Prometheus::Integrations::Resque::ForkReset.installed_in_pid = nil

    run_jobs(RESET_JOB_COUNT)

    expect(exporter.count_for(BACKLOG_METRIC)).to be > RESET_JOB_COUNT
  end

  ##
  # @param [Integer] count
  # @return [void]
  #
  def run_jobs(count)
    count.times { Resque::Job.create(queue, ForkResetProbeJob, 'n' => 1) }
    worker = Resque::Worker.new(queue)

    count.times do
      seed_parent_backlog
      worker.work_one_job
    end
  end

  ##
  # @return [void]
  #
  def seed_parent_backlog
    client_queue << JSON.dump(
      type: 'fork_reset_probe',
      name: BACKLOG_METRIC,
      value: 1.0
    )
  end

  ##
  # @return [Integer]
  #
  def queued_backlog_count
    drained = []
    drained << client_queue.pop(true) until client_queue.empty?
    drained.count { |message| JSON.parse(message)['name'] == BACKLOG_METRIC }
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
