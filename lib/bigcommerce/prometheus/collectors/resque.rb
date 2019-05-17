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
      # Collect metrics to push to the server type collector
      #
      class Resque
        include Bigcommerce::Prometheus::Loggable

        ##
        # @param [Bigcommerce::Prometheus::Client] client
        # @param [Integer] frequency
        #
        def initialize(client:, frequency: nil)
          @client = client || Bigcommerce::Prometheus.client
          @frequency = frequency || 15
        end

        ##
        # Start the collector
        #
        def self.start(client: nil, frequency: nil)
          collector = new(client: client, frequency: frequency)
          Thread.new do
            loop do
              collector.run
            end
          end
        end

        def run
          metric = collect
          logger.debug "[bigcommerce-prometheus] Pushing resque metrics to type collector: #{metric.inspect}"
          @client.send_json metric
        rescue StandardError => e
          logger.error "[bigcommerce-prometheus] Failed to collect resque prometheus stats: #{e.message}"
        ensure
          sleep @frequency
        end

        private

        def collect
          info = ::Resque.info

          metric = {}
          metric[:type] = 'resque'
          metric[:environment] = info[:environment].to_s
          metric[:workers_total] = info[:workers].to_i
          metric[:jobs_failed_total] = info[:failed].to_i
          metric[:jobs_pending_total] = info[:pending].to_i
          metric[:jobs_processed_total] = info[:processed].to_i
          metric[:queues_total] = info[:queues].to_i
          # metric[:queue_size]
          # Resque.queues.each do |queue|
          #   @queue_sizes.set(@labels.merge({ queue: queue }), Resque.size(queue))
          # end
          # @failed_queue_length.set(@labels, Resque.info[:failed])
          metric
        end
      end
    end
  end
end
