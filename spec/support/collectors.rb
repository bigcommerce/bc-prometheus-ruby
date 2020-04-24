# frozen_string_literal: true

# Copyright (c) 2020-present, BigCommerce Pty. Ltd. All rights reserved
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
# frozen_string_literal: true

module Test
  class DynamicCollector < ::Bigcommerce::Prometheus::Collectors::Base
    def add_widget
      push(
        widgets: 1,
        custom_labels: {
          shape: 'round'
        }
      )
    end

    def collect(metrics)
      metrics[:bonks] = 42
      metrics
    end
  end

  class DynamicTypeCollector < ::Bigcommerce::Prometheus::TypeCollectors::Base
    def build_metrics
      {
        bonks: PrometheusExporter::Metric::Counter.new('bonks', 'Running counter of bonks'),
        widgets: PrometheusExporter::Metric::Gauge.new('widgets', 'Current amount of widgets')
      }
    end

    def collect_metrics(data:, labels: {})
      metric(:widgets).observe(data.fetch('widgets', 0), labels)
      metric(:bonks).observe(1, labels) if data.fetch('bonks', 0).to_i.positive?
    end
  end
end
