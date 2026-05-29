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
        # Payload fields for a vanilla Resque job.
        # The top-level 'class' field is the real job class and the args are raw positional values.
        # Vanilla payloads carry no enqueue timestamps, so there is never a queue-latency anchor.
        # As such, queue_latency no-ops for these jobs by construction.
        # perform_duration is unaffected.
        #
        class VanillaResquePayload
          # @return [String] the top-level Resque payload class, or 'unknown' for malformed payloads
          attr_reader :job_class

          # @param [Hash] payload the raw Resque payload which is normalized to a Hash by JobPayload.for
          def initialize(payload)
            @job_class = payload['class'] || 'unknown'
          end

          # @return [nil] vanilla Resque payloads have no enqueue timestamps
          def anchor_time
            nil
          end
        end
      end
    end
  end
end
