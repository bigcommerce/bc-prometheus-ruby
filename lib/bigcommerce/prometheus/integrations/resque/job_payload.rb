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
        # Classifies a Resque::Job's payload and builds the matching
        # shape-specific payload object for per-job metrics.
        #
        # A payload is ActiveJob-shaped when `args[0]` is a Hash carrying a
        # truthy 'job_class' — the shape
        # ActiveJob::QueueAdapters::ResqueAdapter::JobWrapper produces
        # natively. Detection is by shape rather than by wrapper class name:
        # the fields are ActiveJob's stable serialization format (persisted
        # payloads must survive Rails upgrades), while the wrapper's class
        # name is a private Rails constant — matching on it would silently
        # kill the metric if Rails ever moved it. Payloads that replicate
        # these fields are read the same way, by mechanism. Everything
        # else — vanilla Resque jobs with primitive args, nil or non-Hash
        # payloads, `args` not being an Array — is treated as vanilla.
        #
        # Both payload classes expose the same interface: #job_class
        # (String) and #anchor_time (Time or nil).
        #
        module JobPayload
          class << self
            ##
            # Never raises: instrumentation must not break job execution, so a payload object is always returned.
            # Unexpected failures degrade to a vanilla payload labelled 'unknown'.
            #
            # @param [Resque::Job] resque_job
            # @return [ActiveJobPayload, VanillaResquePayload]
            #
            def for(resque_job)
              payload = resque_job.payload
              payload = {} unless payload.is_a?(Hash)

              inner = activejob_inner(payload)
              inner ? ActiveJobPayload.new(inner) : VanillaResquePayload.new(payload)
            rescue StandardError => e
              ::Bigcommerce::Prometheus.logger&.warn(
                "[bigcommerce-prometheus] resque_job payload parse failed: #{e.message}"
              )
              VanillaResquePayload.new({})
            end

            private

            def activejob_inner(payload)
              args  = payload['args']
              first = args.is_a?(Array) ? args.first : nil
              return nil unless first.is_a?(Hash) && first['job_class']

              first
            end
          end
        end
      end
    end
  end
end
