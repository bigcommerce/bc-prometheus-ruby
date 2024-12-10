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
    module Servers
      module Puma
        module Controllers
          ##
          # POST /send-metrics
          #
          class SendMetricsController < BaseController
            class BadMetricsError < StandardError; end

            class InvalidRequestError < StandardError; end

            ##
            # Handle incoming metrics
            #
            def call
              raise InvalidRequestError unless @request.post?

              @server_metrics.add_session
              process_metrics
              succeed!
            rescue InvalidRequestError => _e
              fail!('Invalid request type. Only POST is supported.')
            rescue BadMetricsError => e
              fail!(e.message)
            end

            private

            ##
            # Succeed the request
            #
            def succeed!
              @response['Content-Type'] = 'text/plain'
              @response.write('OK')
              @response.status = 200
              @response
            end

            ##
            # Fail the request
            #
            # @param [String]
            #
            def fail!(message)
              @response['Content-Type'] = 'application/json'
              @response.write([message].to_json)
              @response.status = 500
              @response
            end

            ##
            # Process the metrics
            #
            def process_metrics
              @server_metrics.add_metric
              @collector.process(body)
            rescue StandardError => e
              @logger.error "[bigcommerce-prometheus] Error collecting metrics: #{e.inspect} - #{e.backtrace[0..4].join("\n")}"
              @server_metrics.add_bad_metric
              raise BadMetricsError, e.message
            end

            ##
            # @return [String]
            #
            def body
              @request.body.read
            end
          end
        end
      end
    end
  end
end
