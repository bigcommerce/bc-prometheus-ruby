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
        # Deliver a forked child's own queued metrics before Resque exits and discards them.
        #
        module FlushOnExit
          class << self
            ##
            # @return [PrometheusExporter::Client]
            #
            attr_accessor :client

            ##
            # @return [Symbol|NilClass]
            #
            def flush
              client.flush! if client.respond_to?(:flush!)
            end
          end

          ##
          # @param [Resque::Job] job
          #
          def perform(job, &block)
            super
          ensure
            # fork_per_job? is sufficient here as it will not result in data loss,
            # in contrast with Bigcommerce::Prometheus::Integrations::Resque::ForkReset.reset_if_forked
            FlushOnExit.flush if fork_per_job?
          end
        end
      end
    end
  end
end
