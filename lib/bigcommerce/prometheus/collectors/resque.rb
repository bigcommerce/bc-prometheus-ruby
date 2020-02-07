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
      class Resque < Base
        ##
        # @param [Hash] metrics
        # @return [Hash]
        #
        def collect(metrics = {})
          info = ::Resque.info

          metrics[:environment] = info[:environment].to_s
          metrics[:workers_total] = info[:workers].to_i
          metrics[:jobs_failed_total] = info[:failed].to_i
          metrics[:jobs_pending_total] = info[:pending].to_i
          metrics[:jobs_processed_total] = info[:processed].to_i
          metrics[:queues_total] = info[:queues].to_i
          metrics[:queues] = queue_sizes
          metrics
        end

        def queue_sizes
          queues = {}
          ::Resque.queues.each do |queue|
            queues[queue.to_sym] = ::Resque.size(queue)
          end
          queues
        end
      end
    end
  end
end
