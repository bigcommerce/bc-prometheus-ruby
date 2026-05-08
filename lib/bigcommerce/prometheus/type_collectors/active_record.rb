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
      # Render-side counterpart to Integrations::ActiveRecordSql. Aggregates per-operation
      # SQL query duration into a Prometheus Histogram exposed at /metrics.
      #
      class ActiveRecordSql < Bigcommerce::Prometheus::TypeCollectors::Base
        def initialize(
          default_labels: {},
          buckets: [0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 20, 30, 60]
        )
          @buckets = buckets
          super(type: Bigcommerce::Prometheus::Integrations::ActiveRecordSql::TYPE, default_labels: default_labels)
        end

        def build_metrics
          {
            sql_query_duration_seconds: PrometheusExporter::Metric::Histogram.new(
              'sql_query_duration_seconds',
              'ActiveRecord SQL query duration in seconds, labeled by operation.',
              buckets: @buckets
            )
          }
        end

        def collect_metrics(data:, labels: {})
          duration = data['duration_seconds']
          return if duration.nil?

          metric(:sql_query_duration_seconds).observe(duration.to_f, labels)
        end
      end
    end
  end
end
