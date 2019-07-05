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
require 'timeout'
require 'zlib'
require 'stringio'

module Bigcommerce
  module Prometheus
    module Servers
      module Thin
        ##
        # Server metrics for the collector
        #
        class ServerMetrics
          ##
          # @param [::Logger] logger
          #
          def initialize(logger: nil)
            @logger = logger || ::Bigcommerce::Prometheus.logger
            @metrics_total = ::PrometheusExporter::Metric::Counter.new('collector_metrics_total', 'Total metrics processed by exporter.')
            @sessions_total = ::PrometheusExporter::Metric::Counter.new('collector_sessions_total', 'Total send_metric sessions processed by exporter.')
            @bad_metrics_total = ::PrometheusExporter::Metric::Counter.new('collector_bad_metrics_total', 'Total mis-handled metrics by collector.')
            @collector_working_gauge = ::PrometheusExporter::Metric::Gauge.new('collector_working', 'Is the master process collector able to collect metrics')
            @collector_rss_gauge = ::PrometheusExporter::Metric::Gauge.new('collector_rss', 'total memory used by collector process')
          end

          def add_session
            @sessions_total.observe
          end

          def add_metric
            @metrics_total.observe
          end

          def add_bad_metric
            @bad_metrics_total.observe
          end

          ##
          # @param [Boolean] working
          # @return [String]
          #
          def to_prometheus_text(working: true)
            collect(working: working).map(&:to_prometheus_text).join("\n\n")
          end

          private

          ##
          # Collect server metrics
          #
          # @param [Boolean] working
          #
          def collect(working: true)
            @collector_working_gauge.observe(working ? 1 : 0)
            @collector_rss_gauge.observe(rss)

            [
              @metrics_total,
              @sessions_total,
              @bad_metrics_total,
              @collector_working_gauge,
              @collector_rss_gauge
            ]
          end

          ##
          # Get RSS size of the current process
          #
          # @return [Integer]
          #
          def rss
            _pid, size = `ps ax -o pid,rss | grep -E "^[[:space:]]*#{::Process.pid}"`.strip.split.map(&:to_i)
            size
          rescue StandardError => e
            @logger.error "Failed to get RSS size: #{e.message}"
            0
          end
        end
      end
    end
  end
end
