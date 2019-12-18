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

# Puma mock
class Puma
  def self.stats
    {
      'phase' => 0,
      'workers' => rand(8..12),
      'booted_workers' => 10,
      'old_workers' => 0,
      'worker_status' => []
    }.to_json
  end
end

# Custom type collector
module Demo
  class GeeseTypeCollector < Bigcommerce::Prometheus::TypeCollectors::Base
    def build_metrics
      {
        geese_total: PrometheusExporter::Metric::Gauge.new('geese_total', 'Number of geese')
      }
    end

    def collect_metrics(data:, labels: {})
      metric(:geese_total)&.observe(data['geese_total'], labels)
    end
  end

  # Custom collector
  class GeeseCollector < Bigcommerce::Prometheus::Collectors::Base
    def collect(metrics)
      metrics[:geese_total] = rand(100)
      metrics
    end
  end
end
