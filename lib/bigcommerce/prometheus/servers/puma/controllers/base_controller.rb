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
          # Base puma controller for prometheus metrics
          #
          class BaseController
            ##
            # @param [Rack::Request] request
            # @param [Rack::Response] response
            # @param [Bigcommerce::Prometheus::Servers::Puma::ServerMetrics]
            # @param [PrometheusExporter::Server::Collector] collector
            # @param [Logger] logger
            #
            def initialize(request:, response:, server_metrics:, collector:, logger:)
              @request = request
              @response = response
              @collector = collector
              @server_metrics = server_metrics
              @logger = logger
            end

            def handle
              call
              @response.finish
            end

            ##
            # @param [String] key
            # @param [String] value
            #
            def set_header(key, value)
              if @response.respond_to?(:add_header) # rack 2.0+
                @response.add_header(key.to_s, value.to_s)
              else
                @response[key.to_s] = value.to_s
              end
            end
          end
        end
      end
    end
  end
end
