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
    module TypeCollectors
      ##
      # Aggregates per-Resque-job histogram observations (`type: 'resque_job'`) pushed from worker processes by
      # `Bigcommerce::Prometheus::Integrations::Resque::JobMetrics`.
      #
      class ResqueJob < Bigcommerce::Prometheus::TypeCollectors::Base
        ##
        # Override the auto-derived type so envelopes tagged `type: 'resque_job'` route to this collector via
        # `PrometheusExporter::Server::Collector`.
        #
        def initialize(default_labels: {})
          super(type: 'resque_job', default_labels: default_labels)
        end

        ##
        # @return [Hash]
        #
        def build_metrics
          {
            queue_latency: build_queue_latency_histogram,
            perform_duration: build_perform_duration_histogram
          }
        end

        ##
        # Observe the histogram for the named metric.
        # Labels have already been merged with `custom_labels` by `TypeCollectors::Base#collect`.
        #
        def collect_metrics(data:, labels: {})
          name = data['metric']
          return unless %w[queue_latency perform_duration].include?(name)

          metric(name.to_sym).observe(data['value'], labels)
        end

        private

        def build_queue_latency_histogram
          PrometheusExporter::Metric::Histogram.new(
            'resque_job_queue_latency_seconds',
            'Seconds between when a Resque job was due to run (scheduled_at if set, ' \
            'falling back to enqueued_at) and when a worker process picked it up. ' \
            'Recorded per attempt; retries-with-backoff anchor on scheduled_at, ' \
            'excluding the intentional backoff wait. Opt-in via ' \
            'PROMETHEUS_RESQUE_PER_JOB_METRICS_ENABLED.',
            buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 30, 60, 120, 300]
          )
        end

        def build_perform_duration_histogram
          PrometheusExporter::Metric::Histogram.new(
            'resque_job_perform_duration_seconds',
            'Total Resque child process lifetime (fork to waitpid). Includes ' \
            'fork overhead, Redis reconnect, after_fork hooks, perform, and ' \
            'exit. Used as the per-job throughput signal at the worker-pod ' \
            'level. Opt-in via PROMETHEUS_RESQUE_PER_JOB_METRICS_ENABLED.',
            buckets: [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60]
          )
        end
      end
    end
  end
end
