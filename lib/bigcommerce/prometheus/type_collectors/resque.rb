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
      # Collect resque data from collectors and parse them into metrics
      #
      class Resque < PrometheusExporter::Server::TypeCollector
        ##
        # Initialize the collector
        #
        def initialize
          @workers_total = PrometheusExporter::Metric::Gauge.new('resque_workers_total', 'Number of active workers')
          @jobs_failed_total = PrometheusExporter::Metric::Gauge.new('jobs_failed_total', 'Number of failed jobs')
          @jobs_pending_total = PrometheusExporter::Metric::Gauge.new('jobs_pending_total', 'Number of pending jobs')
          @jobs_processed_total = PrometheusExporter::Metric::Gauge.new('jobs_processed_total', 'Number of processed jobs')
          @queues_total = PrometheusExporter::Metric::Gauge.new('queues_total', 'Number of total queues')
        end

        ##
        # @return [String]
        #
        def type
          'resque'
        end

        ##
        # @return [Array]
        #
        def metrics
          return [] unless @workers_total

          [
            @workers_total,
            @jobs_failed_total,
            @jobs_pending_total,
            @jobs_processed_total,
            @queues_total
          ]
        end

        ##
        # Collect resque metrics from input data
        #
        def collect(obj)
          default_labels = { environment: obj['environment'] }
          custom_labels = obj['custom_labels']
          labels = custom_labels.nil? ? default_labels : default_labels.merge(custom_labels)

          @workers_total.observe(obj['workers_total'], labels)
          @jobs_failed_total.observe(obj['jobs_failed_total'], labels)
          @jobs_pending_total.observe(obj['jobs_pending_total'], labels)
          @jobs_processed_total.observe(obj['jobs_processed_total'], labels)
          @queues_total.observe(obj['queues_total'], labels)
        end
      end
    end
  end
end
