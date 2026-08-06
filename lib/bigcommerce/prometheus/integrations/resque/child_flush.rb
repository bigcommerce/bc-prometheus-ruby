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
    module Integrations
      class Resque
        ##
        # Deliver a forked child's observations before Resque tears it down, by waiting on the client's background
        # drain thread.
        #
        # This is not a proposal. It reconstructs the approach taken by bigpay PR #10597, which shipped and was
        # reverted, so that the fork delivery specs can be run against it.
        #
        module ChildFlush
          # bigpay passed 2 seconds. The value is an upper bound, not a cost: `stop` returns as soon as the queue is
          # observed empty.
          WAIT_TIMEOUT_SECONDS = 2

          def perform(job, &block)
            super
          ensure
            ::Bigcommerce::Prometheus.client.stop(wait_timeout_seconds: WAIT_TIMEOUT_SECONDS) if fork_per_job?
          end
        end
      end
    end
  end
end
