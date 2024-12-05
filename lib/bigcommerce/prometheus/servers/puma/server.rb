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
        ##
        # Puma adapter for server
        #
        class Server < ::Puma::Server
          def initialize(port: nil, host: nil, timeout: nil, logger: nil, thread_pool_size: nil)
            @port = port || ::Bigcommerce::Prometheus.server_port
            @host = host || ::Bigcommerce::Prometheus.server_host
            @timeout = timeout || ::Bigcommerce::Prometheus.server_timeout
            @logger = logger || ::Bigcommerce::Prometheus.logger
            @rack_app = ::Bigcommerce::Prometheus::Servers::Puma::RackApp.new(timeout: timeout, logger: logger)
            thread_pool_size = (thread_pool_size || ::Bigcommerce::Prometheus.server_thread_pool_size).to_i
            super(@rack_app, nil, max_threads: thread_pool_size)
            add_tcp_listener(@host, @port)
            @logger.info "[bigcommerce-prometheus] Prometheus server started on #{@host}:#{@port}"
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
