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
# Pushes a metric and then keeps working for a moment.
#
# The pause matters. Pushing only queues, and the child's background delivery thread starts on that first push and
# attempts a delivery straight away. Without the pause the child's `exit!` usually beats that attempt, so nothing is
# sent and the spec would pass against a child that had inherited the parent's whole backlog.
#
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

##
# Black box: proves a forked child does not send what the parent had queued.
#
# Forks real children and needs a redis.
# To run it:
#   FORK_INTEGRATION=1 REDIS_URL=redis://127.0.0.1:6379/15 bundle exec rspec spec/integration
#
describe 'a forked Resque child and the queue it inherits', :fork_integration do
  # A constant declared in a `describe` block lands on Object, so it has to be unique across the whole suite rather
  # than only within this file.
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
    # Raise rather than skip.
    # The tag filter means this hook only runs when the run asked for these specs, so a missing redis is a broken
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
    end

    # `Bigcommerce::Prometheus.client` is a `Singleton`, so this run cannot get a fresh one.
    # It captured its host, port and thread sleep when first built, which an earlier spec in the run may already
    # have done. Reconfiguring that instance and dropping whatever it has queued keeps the result independent of
    # spec ordering.
    #
    # The parent must not drain the backlog seeded below, or there would be nothing for a child to inherit and the
    # assertions would hold for the wrong reason. Killing the thread and lengthening its sleep means the next one
    # makes a single pass and then stays asleep for the rest of the run.
    client.instance_variable_get(:@worker_thread)&.kill
    client.instance_variable_set(:@host, '127.0.0.1')
    client.instance_variable_set(:@port, exporter.port)
    client.instance_variable_set(:@thread_sleep, PARENT_THREAD_SLEEP)
    client.reset_after_fork!

    Bigcommerce::Prometheus::Integrations::Resque.start(client: client)

    # `start` pushes its first instrumentation metrics, which starts the delivery thread and gives it one pass.
    # Waiting for that pass to finish before seeding is what keeps the seeds off the wire.
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

  # Without this the assertion above would pass on a run where the seeding silently did nothing, which is the one
  # way this spec could go green while the reset was broken.
  it 'leaves the seeded backlog on the parent queue, which is what the children inherited a copy of' do
    run_jobs(RESET_JOB_COUNT)

    expect(queued_backlog_count).to eq RESET_JOB_COUNT
  end

  # Proves the first example can fail, which is what makes it worth having.
  #
  # `ForkReset.reset_if_forked` returns early when no pid was recorded, so clearing it reproduces the behavior this
  # pull request fixes. No configuration is involved, and the module stays prepended.
  #
  # Each child inherits every seed the parent has queued so far, so the arrivals approach the triangular number for
  # RESET_JOB_COUNT. Locally that is 210 of 210, on every run.
  # The assertion stays loose because how much of that backlog a child sends before `exit!` is a race, and a loaded
  # CI runner will not always reach the whole of it.
  it 're-sends the parent backlog when the reset is inactive, which is the behavior being fixed' do
    Bigcommerce::Prometheus::Integrations::Resque::ForkReset.installed_in_pid = nil

    run_jobs(RESET_JOB_COUNT)

    expect(exporter.count_for(BACKLOG_METRIC)).to be > RESET_JOB_COUNT
  end

  # Deliberately not asserted: that the child's own observation arrives.
  # Without a synchronous flush that is a race between the job and the delivery thread.

  # --- helpers -----------------------------------------------------------

  # Drains the queue by calling `work_one_job` directly rather than `Worker#work`, whose poll loop sleeps for its
  # interval whenever `reserve` finds nothing.
  # Each call still forks, runs the after_fork hooks and exits the child exactly as a live worker does.
  #
  # @param [Integer] count
  # @return [void]
  def run_jobs(count)
    count.times { Resque::Job.create(queue, ForkResetProbeJob, 'n' => 1) }
    worker = Resque::Worker.new(queue)

    count.times do
      seed_parent_backlog
      worker.work_one_job
    end
  end

  # Puts a message on the parent's queue immediately before a fork, so every child inherits a copy of one.
  #
  # Pushed straight onto the queue rather than through `Client#send`, which would start the parent's delivery
  # thread and drain the seed before the fork.
  #
  # @return [void]
  def seed_parent_backlog
    client_queue << JSON.dump(
      type: 'fork_reset_probe',
      name: BACKLOG_METRIC,
      value: 1.0
    )
  end

  # Drains the parent's queue and counts the seeds still on it.
  #
  # The collectors push onto the same queue, so its size alone says nothing about the backlog.
  # Destructive, and called at the end of an example for that reason.
  #
  # @return [Integer]
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
