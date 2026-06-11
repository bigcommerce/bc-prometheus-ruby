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
module Bigcommerce
  module Prometheus
    module Integrations
      class Resque
        ##
        # Per-Resque-job histogram metrics, recorded from the parent worker process.
        # Hooked via a prepend around Resque::Worker#perform_with_fork.
        # Queue latency is captured before super, perform duration after.
        #
        # Off unless PROMETHEUS_RESQUE_PER_JOB_METRICS_ENABLED=1
        # Emits one histogram observation per job per worker process, which can be high cardinality at scale.
        #
        # NOTE: queue_latency is supported for jobs enqueued via ActiveJob
        # The gem reads three fields from
        # `payload['args'][0]` (which must be a Hash):
        #
        #   * job_class    — the user's actual job class name; used as the
        #                    metric label.
        #   * enqueued_at  — ISO 8601 string; used as the queue-latency
        #                    anchor when scheduled_at is absent.
        #   * scheduled_at — ISO 8601 string; preferred over enqueued_at
        #                    when present (e.g. retries-with-backoff, so
        #                    the intentional wait isn't counted as latency).
        #
        # ActiveJob produces this shape natively — the payload is wrapped by
        # ActiveJob::QueueAdapters::ResqueAdapter::JobWrapper, which stamps
        # the three fields above into `args[0]`.
        #
        # Vanilla Resque jobs enqueued via Resque.enqueue carry no enqueue timestamps.
        # class MyJob
        #   @queue = :foo;
        #   def self.perform;
        # end
        # Their args are raw primitive values, not a wrapping hash.
        # For these jobs, queue_latency silently no-ops.
        # perform_duration works for both styles regardless.
        #
        # Payloads that replicate the three fields above are read the same way.
        # Detection is by shape, not by wrapper class name.
        # This means a vanilla job can opt in to queue_latency either by
        # - converting to ActiveJob
        # - enqueueing through a small wrapper class that stamps these fields into args[0].
        #
        module JobMetrics
          class << self
            ##
            # Install the parent-side hooks if the per-job metrics feature is enabled.
            # Idempotent: safe to call multiple times.
            #
            # @param [PrometheusExporter::Client] client
            #
            def start(client:)
              return unless ::Bigcommerce::Prometheus.resque_per_job_metrics_enabled

              @client = client
              log_install_state
              install_hooks
            end

            ##
            # Push the queue-latency observation for a job that's about to be picked up by a worker.
            # Anchors on scheduled_at if present so retries-with-backoff don't show the intentional wait as latency.
            # Falls back to enqueued_at if scheduled_at isn't present.
            #
            # @param [ActiveJobPayload, VanillaResquePayload] payload
            #
            def record_queue_latency(payload)
              anchor = payload.anchor_time
              return unless anchor

              # Clock skew between the enqueuer/scheduler and the worker can put the anchor in the future.
              # Clamp to zero so the histogram never records a negative latency.
              latency = (Time.now - anchor).to_f.clamp(0.0..)

              @client.send_json(
                type: 'resque_job',
                metric: 'queue_latency',
                value: latency,
                custom_labels: { job_class: payload.job_class }
              )
            rescue StandardError => e
              ::Bigcommerce::Prometheus.logger&.warn(
                "[bigcommerce-prometheus] resque_job queue_latency push failed: #{e.message}"
              )
            end

            ##
            # Push the perform-duration observation for a completed job.
            # Called from the `Resque::Worker#perform_with_fork` prepend, so it measures the full child lifetime:
            # fork + reconnect + perform + exit
            #
            # Computed here rather than by the caller so the rescue below covers the
            # arithmetic — the caller invokes this from an ensure block that must never raise.
            #
            # @param [ActiveJobPayload, VanillaResquePayload] payload
            # @param [Float] started_at monotonic timestamp taken just before the fork
            #
            def record_perform_duration(payload, started_at)
              @client.send_json(
                type: 'resque_job',
                metric: 'perform_duration',
                value: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at,
                custom_labels: { job_class: payload.job_class }
              )
            rescue StandardError => e
              ::Bigcommerce::Prometheus.logger&.warn(
                "[bigcommerce-prometheus] resque_job perform_duration push failed: #{e.message}"
              )
            end

            private

            def install_hooks
              return if @hooks_installed

              ::Resque::Worker.prepend(WorkerInstrumentation)
              @hooks_installed = true
            end

            ##
            # Surface at boot whether the worker can actually be observed — per-job metrics are
            # opt-in and must not be silently absent. Must run before install_hooks: the prepend
            # itself defines perform_with_fork, which would satisfy the presence check.
            #
            def log_install_state
              unless worker_defines_perform_with_fork?
                ::Bigcommerce::Prometheus.logger&.warn(
                  '[bigcommerce-prometheus] resque_job metrics are enabled but Resque::Worker#perform_with_fork ' \
                  'is not defined (requires resque >= 1.27); per-job metrics will not be recorded'
                )
                return
              end

              if ENV['FORK_PER_JOB'] == 'false' || !Kernel.respond_to?(:fork)
                ::Bigcommerce::Prometheus.logger&.warn(
                  '[bigcommerce-prometheus] resque_job metrics are enabled but the worker is not forking per job; ' \
                  'only the forking path is instrumented, so per-job metrics will not be recorded'
                )
                return
              end

              ::Bigcommerce::Prometheus.logger&.info(
                '[bigcommerce-prometheus] resque_job per-job metrics enabled; instrumenting Resque::Worker (fork-per-job mode)'
              )
            end

            def worker_defines_perform_with_fork?
              ::Resque::Worker.method_defined?(:perform_with_fork) ||
                ::Resque::Worker.private_method_defined?(:perform_with_fork)
            end
          end

          ##
          # Prepended onto Resque::Worker to capture for every job that goes through perform_with_fork:
          # - queue latency: before super
          # - perform duration: after super
          module WorkerInstrumentation
            def perform_with_fork(job, &block)
              payload = JobPayload.for(job)
              JobMetrics.record_queue_latency(payload)
              started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              super
            ensure
              JobMetrics.record_perform_duration(payload, started_at)
            end
          end
        end
      end
    end
  end
end
