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
        @running = false
        @process_name = ::Bigcommerce::Prometheus.process_name
      end

      ##
      # Start the server
      #
      def start
        setup_signal_handlers

        logger.info "[bigcommerce-prometheus][#{@process_name}] Starting prometheus exporter on port #{@port}"
        server.start
        logger.info "[bigcommerce-prometheus][#{@process_name}] Prometheus exporter started on port #{@port}"

        @running = true
        server
      rescue StandardError => e
        logger.error "[bigcommerce-prometheus][#{@process_name}] Failed to start exporter: #{e.message}"
        stop
      end

      ##
      # Stop the server
      #
      def stop
        logger.info "[bigcommerce-prometheus][#{@process_name}] Shutting down prometheus exporter"
        server.stop
        logger.info "[bigcommerce-prometheus][#{@process_name}] Prometheus exporter cleanly shut down"
      rescue StandardError => e
        logger.error "[bigcommerce-prometheus][#{@process_name}] Failed to stop exporter: #{e.message}"
      end

      ##
      # Whether or not the server is running
      #
      # @return [Boolean]
      #
      def running?
        @running
      end

      ##
      # Add a type collector to this server
      #
      # @param [PrometheusExporter::Server::TypeCollector] collector
      #
      def add_type_collector(collector)
        runner.type_collectors = runner.type_collectors.push(collector)
      end

      private

      ##
      # @return [::PrometheusExporter::Server::Runner]
      # 
      def runner
        unless @runner
          @runner = ::PrometheusExporter::Server::Runner.new(
            timeout: @timeout,
            port: @port,
            prefix: @prefix,
            verbose: @verbose
          )
          PrometheusExporter::Metric::Base.default_prefix = @runner.prefix
        end
        @runner
      end

      ##
      # Register signal handlers
      #
      # :nocov:
      def setup_signal_handlers
        Signal.trap('INT', &method(:stop))
        Signal.trap('TERM', &method(:stop))
      end
      # :nocov:

      def server
        @server ||= begin
          runner.send(:register_type_collectors)
          runner.server_class.new(
            port: runner.port,
            collector: runner.collector,
            timeout: runner.timeout,
            verbose: runner.verbose
          )
        end
      end
    end
  end
end
