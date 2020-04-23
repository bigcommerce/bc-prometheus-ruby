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
    module Collectors
      ##
      # Base class for collectors
      #
      class Base
        ##
        # Start the collector
        #
        def self.start(*args, &block)
          process_collector = new(*args, &block)

          stop if @thread

          @thread = Thread.new do
            Kernel.loop do
              process_collector.run
            end
          end
        end

        ##
        # Stop the collector
        #
        def self.stop
          t = @thread
          return unless t

          t.kill
          @thread = nil
        end

        ##
        # @param [Bigcommerce::Prometheus::Client] client
        # @param [String] type
        # @param [Integer] frequency
        # @param [Hash] options
        #
        def initialize(client: nil, type: nil, frequency: nil, options: nil)
          @client = client || Bigcommerce::Prometheus.client
          @type = type || self.class.to_s.downcase.gsub('::', '_').gsub('collector', '')
          @frequency = frequency || Bigcommerce::Prometheus.collector_collection_frequency
          @options = options || {}
          @logger = Bigcommerce::Prometheus.logger
        end

        ##
        # Run the collector and send stats
        #
        def run
          metrics = {}
          metrics = collect(metrics)
          push(metrics)
        ensure
          sleep @frequency
        end

        ##
        # Collect metrics. This should be overridden in derivative collectors
        #
        # @param [Hash] metrics
        # @return [Hash]
        #
        def collect(metrics = {})
          metrics
        end

        private

        ##
        # @param [Hash] metric
        #
        def push(metric)
          metric[:type] = @type unless metric.key?(:type)
          @logger.debug("[bigcommerce-prometheus] Pushing #{metric[:type]} metrics to type collector: #{metric.inspect}")
          @client.send_json(metric)
        rescue StandardError => e
          @logger.error("[bigcommerce-prometheus] Prometheus Exporter failed to send #{metric[:type]} stats to type collector #{e}")
        end
      end
    end
  end
end
