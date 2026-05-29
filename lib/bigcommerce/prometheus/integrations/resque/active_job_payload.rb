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
require 'time'

module Bigcommerce
  module Prometheus
    module Integrations
      class Resque
        ##
        # Payload fields for an ActiveJob-shaped Resque job, read from the
        # inner hash at `args[0]`. ActiveJob's JobWrapper stamps the three
        # fields the per-job metrics consume:
        #
        #   * job_class    — the user's actual job class name; used as the
        #                    metric label.
        #   * enqueued_at  — ISO 8601 string; queue-latency anchor when
        #                    scheduled_at is absent.
        #   * scheduled_at — ISO 8601 string; preferred over enqueued_at
        #                    when present (e.g. retries-with-backoff, so the
        #                    intentional wait isn't counted as latency).
        class ActiveJobPayload
          # @return [String] the user's actual job class name
          attr_reader :job_class

          # @return [Time, nil] the queue-latency anchor; nil when both
          #   timestamps are absent or unparseable
          attr_reader :anchor_time

          # @param [Hash] inner the ActiveJob-shaped hash at `args[0]`;
          #   JobPayload.for guarantees a truthy 'job_class'
          def initialize(inner)
            @job_class   = inner['job_class']
            @anchor_time = parse_time(inner['scheduled_at']) || parse_time(inner['enqueued_at'])
          end

          private

          def parse_time(value)
            return value if value.is_a?(Time)
            return nil if value.nil? || value.to_s.empty?

            Time.iso8601(value.to_s)
          rescue ArgumentError
            nil
          end
        end
      end
    end
  end
end
