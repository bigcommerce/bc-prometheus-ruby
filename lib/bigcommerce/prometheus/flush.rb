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
    ##
    # Flushes metrics prior to exiting
    #
    class Flush
      ##
      # Result of the flush
      #
      class Outcome
        attr_reader :kind, :message, :context

        def initialize(kind:, message: nil, context: {})
          @kind = kind
          @message = message
          @context = context
        end

        def success? = kind == :success
        def empty? = kind == :empty
        def timeout? = kind == :timeout
        def error? = kind == :error

        def ==(other)
          other.is_a?(Symbol) ? kind == other : super
        end

        def self.from_post_failed(error)
          new(kind: :error, message: error.message)
        end

        def self.timeout(undelivered:, uri_path:)
          new(
            kind: :timeout,
            message: "timeout delivering metrics in_flight=1 undelivered=#{undelivered}",
            context: { uri: uri_path }
          )
        end

        def self.from_process_queue(process_queue_result)
          new(kind: process_queue_result)
        end
      end

      def initialize(delivery:, timeout:)
        @delivery = delivery
        @timeout = timeout
      end

      def call
        attempt_within_budget
      end

      private

      def attempt_within_budget
        worker = Thread.new { attempt }
        return worker.value if worker.join(@timeout)

        worker.kill
        Outcome.timeout(undelivered: @delivery.queue_size, uri_path: uri_path)
      end

      def attempt
        Outcome.from_process_queue(@delivery.process_queue)
      rescue Delivery::PostFailed => e
        Outcome.from_post_failed(e)
      end

      def uri_path
        @delivery.uri_path('/send-metrics')
      end
    end
  end
end
