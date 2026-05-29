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
        # Extracts the fields per-job metrics need from a Resque::Job's
        # payload. Eagerly parses in #initialize and exposes plain
        # attr_readers — does not hold a reference to the Resque::Job after
        # construction.
        #
        # See JobMetrics's class-level docs for the ActiveJob-shaped payload
        # contract this class consumes.
        #
        class JobPayload
          # @return [String] the user's actual job class name. For
          #   ActiveJob-shaped payloads this is `args[0]['job_class']`.
          #   Falls back to the top-level Resque `class` field for vanilla
          #   Resque payloads. `'unknown'` if neither is available, or if
          #   the payload is malformed (nil, non-Hash, etc.).
          attr_reader :job_class

          # @return [Time, nil] the queue-latency anchor. Prefers
          #   `scheduled_at` over `enqueued_at` (so retries-with-backoff
          #   don't count the intentional wait). nil for non-ActiveJob-shaped
          #   payloads (where `args[0]` isn't a Hash), for payloads where
          #   both timestamps are absent or unparseable, and for malformed
          #   payloads.
          attr_reader :anchor_time

          # @param [Resque::Job] resque_job
          def initialize(resque_job)
            payload = resque_job.payload || {}
            inner   = extract_activejob_inner(payload)

            @job_class   = extract_job_class(payload, inner)
            @anchor_time = extract_anchor_time(inner)
          end

          private

          # Returns the inner ActiveJob-shaped payload (`args[0]` if it's a
          # Hash), or nil for any payload shape that isn't ActiveJob-wrapped
          # (vanilla Resque jobs with primitive args, non-Hash payloads,
          # `args` not being an Array, etc.).
          def extract_activejob_inner(payload)
            return nil unless payload.is_a?(Hash)

            args  = payload['args']
            first = args.is_a?(Array) ? args.first : nil
            first.is_a?(Hash) ? first : nil
          end

          def extract_job_class(payload, inner)
            inner_class = inner.is_a?(Hash) ? inner['job_class'] : nil
            outer_class = payload.is_a?(Hash) ? payload['class'] : nil
            inner_class || outer_class || 'unknown'
          end

          def extract_anchor_time(inner)
            return nil unless inner.is_a?(Hash)

            parse_time(inner['scheduled_at']) || parse_time(inner['enqueued_at'])
          end

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
