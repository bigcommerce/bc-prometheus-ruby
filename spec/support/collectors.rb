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

class AppCollector < ::Bigcommerce::Prometheus::Collectors::Base
  def honk!
    push(
      honks: 1,
      custom_labels: {
        volume: 'loud'
      }
    )
  end

  def collect(metrics)
    metrics[:points] = 42
    metrics
  end
end

class AppTypeCollector < ::Bigcommerce::Prometheus::TypeCollectors::Base
  def build_metrics
    {
      honks: PrometheusExporter::Metric::Counter.new('honks', 'Running counter of honks'),
      points: PrometheusExporter::Metric::Gauge.new('points', 'Current amount of points')
    }
  end

  def collect_metrics(data:, labels: {})
    metric(:honks).observe(1, labels) if data.fetch('honks', 0).to_i.positive?
    metric(:points).observe(data.fetch('points', 0), labels)
  end
end
