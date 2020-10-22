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
      # Base type collector class
      #
      class Base < PrometheusExporter::Server::TypeCollector
        attr_reader :type

        ##
        # @param [String] type
        # @param [Hash] default_labels
        #
        def initialize(type: nil, default_labels: {})
          super()
          @type = type || self.class.to_s.downcase.gsub('::', '_').gsub('typecollector', '')
          @default_labels = default_labels || {}
          @metrics = build_metrics
        end

        ##
        # @return [Array]
        #
        def metrics
          return [] unless @metrics.any?

          @metrics.values
        end

        ##
        # @param [Symbol] key
        #
        def metric(key)
          @metrics.fetch(key.to_sym, nil)
        end

        ##
        # Collect metrics from input data
        #
        # @param [Hash] data
        #
        def collect(data)
          custom_labels = data.fetch('custom_labels', nil)
          labels = custom_labels.nil? ? @default_labels : @default_labels.merge(custom_labels)
          collect_metrics(data: data, labels: labels)
        end

        private

        ##
        # Collect metrics. Implementations of translating metrics to observed calls should happen here.
        #
        def collect_metrics(*)
          raise NotImplementedError, 'Must implement collect_metrics'
        end

        ##
        # Build and return all observable metrics. This should be a hash of symbol keys that map to
        # PrometheusExporter::Metric::Base objects.
        #
        # @return [Hash]
        #
        def build_metrics
          {}
        end
      end
    end
  end
end
