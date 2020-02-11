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
      class Resque < Bigcommerce::Prometheus::TypeCollectors::Base
        ##
        # Initialize the collector
        #
        def build_metrics
          {
            workers_total: PrometheusExporter::Metric::Gauge.new('resque_workers_total', 'Number of active workers'),
            jobs_failed_total: PrometheusExporter::Metric::Gauge.new('jobs_failed_total', 'Number of failed jobs'),
            jobs_pending_total: PrometheusExporter::Metric::Gauge.new('jobs_pending_total', 'Number of pending jobs'),
            jobs_processed_total: PrometheusExporter::Metric::Gauge.new('jobs_processed_total', 'Number of processed jobs'),
            queues_total: PrometheusExporter::Metric::Gauge.new('queues_total', 'Number of total queues'),
            queue_sizes: PrometheusExporter::Metric::Gauge.new('queue_sizes', 'Size of each queue')
          }
        end

        ##
        # Collect resque metrics from input data
        #
        def collect_metrics(data:, labels: {})
          metric(:workers_total).observe(data['workers_total'], labels)
          metric(:jobs_failed_total).observe(data['jobs_failed_total'], labels)
          metric(:jobs_pending_total).observe(data['jobs_pending_total'], labels)
          metric(:jobs_processed_total).observe(data['jobs_processed_total'], labels)
          metric(:queues_total).observe(data['queues_total'], labels)

          data['queues'].each do |name, size|
            metric(:queue_sizes).observe(size, labels.merge(queue: name))
          end
        end
      end
    end
  end
end
