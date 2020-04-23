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
        # Thin adapter for server
        #
        class Server < ::Thin::Server
          def initialize(port:, host: nil, timeout: nil, logger: nil)
            @port = port || ::Bigcommerce::Prometheus.server_port
            @host = host || ::Bigcommerce::Prometheus.server_host
            @timeout = timeout || ::Bigcommerce::Prometheus.server_timeout
            @logger = logger || ::Bigcommerce::Prometheus.logger
            @rack_app = ::Bigcommerce::Prometheus::Servers::Thin::RackApp.new(timeout: timeout, logger: logger)
            super(@host, @port, @rack_app)
            ::Thin::Logging.logger = @logger
          end

          ##
          # Add a type collector to this server
          #
          # @param [PrometheusExporter::Server::TypeCollector] collector
          #
          def add_type_collector(collector)
            @rack_app.add_type_collector(collector)
          end
        end
      end
    end
  end
end
