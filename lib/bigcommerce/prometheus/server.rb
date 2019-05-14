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
    # Server implementation for Prometheus
    #
    class Server
      include Loggable

      ##
      # @param [Integer] port
      # @param [Integer] timeout
      # @param [String] prefix
      # @param [Boolean] verbose
      #
      def initialize(port: nil, timeout: nil, prefix: nil, verbose: false)
        @port = (port || ::PrometheusExporter::DEFAULT_PORT).to_i
        @timeout = (timeout || ::PrometheusExporter::DEFAULT_TIMEOUT).to_i
        @prefix = (prefix || ::PrometheusExporter::DEFAULT_PREFIX).to_s
        @verbose = verbose
      end

      ##
      # Start the server
      #
      def start
        runner = ::PrometheusExporter::Server::Runner.new(
          timeout: @timeout,
          port: @port,
          prefix: @prefix,
          verbose: @verbose
        )
        logger.info "[bigcommerce-prometheus] Starting prometheus exporter on port #{@port}"
        runner.start
      end
    end
  end
end
