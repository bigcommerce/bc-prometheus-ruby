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
      module Thin
        ##
        # Handles metrics requests as a Rack App on the Thin server
        #
        class RackApp
          ##
          #
          def initialize(collector: nil, timeout: nil, logger: nil)
            @timeout = timeout || ::Bigcommerce::Prometheus.server_timeout
            @collector = collector || ::PrometheusExporter::Server::Collector.new
            @logger = logger || ::Bigcommerce::Prometheus.logger
            @server_metrics = ::Bigcommerce::Prometheus::Servers::Thin::ServerMetrics.new(logger: @logger)
          end

          def call(env)
            request = ::Rack::Request.new(env)
            response = ::Rack::Response.new
            controller = route(request)
            handle(controller: controller, request: request, response: response)
          rescue StandardError => e
            @logger.error "Error: #{e.message}"
            handle(controller: ::Bigcommerce::Prometheus::Servers::Thin::Controllers::ErrorController, request: request, response: response)
          end

          ##
          # Add a type collector to this server
          #
          # @param [PrometheusExporter::Server::TypeCollector] collector
          #
          def add_type_collector(collector)
            @collector.register_collector(collector)
          end

          private

          ##
          # Determine the controller route
          #
          # @param [Rack::Request] request
          #
          def route(request)
            if request.fullpath == '/metrics' && request.request_method.to_s.downcase == 'get'
              Bigcommerce::Prometheus::Servers::Thin::Controllers::MetricsController
            elsif request.fullpath == '/send-metrics' && request.request_method.to_s.downcase == 'post'
              Bigcommerce::Prometheus::Servers::Thin::Controllers::SendMetricsController
            else
              Bigcommerce::Prometheus::Servers::Thin::Controllers::NotFoundController
            end
          end

          ##
          # Handle a controller request
          #
          def handle(controller:, request:, response:)
            con = controller.new(
              request: request,
              response: response,
              server_metrics: @server_metrics,
              collector: @collector,
              logger: @logger
            )
            con.handle
          end
        end
      end
    end
  end
end
