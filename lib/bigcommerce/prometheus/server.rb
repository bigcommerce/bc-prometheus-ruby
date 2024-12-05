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
      ##
      # @param [String] host
      # @param [Integer] port
      # @param [Integer] timeout
      # @param [String] prefix
      # @param [Integer] thread_pool_size
      #
      def initialize(host: nil, port: nil, timeout: nil, prefix: nil, logger: nil, thread_pool_size: nil)
        @host = host || ::Bigcommerce::Prometheus.server_host
        @port = (port || ::Bigcommerce::Prometheus.server_port).to_i
        @timeout = (timeout || ::Bigcommerce::Prometheus.server_timeout).to_i
        @prefix = (prefix || ::PrometheusExporter::DEFAULT_PREFIX).to_s
        @process_name = ::Bigcommerce::Prometheus.process_name
        @logger = logger || ::Bigcommerce::Prometheus.logger
        @server = ::Bigcommerce::Prometheus::Servers::Puma::Server.new(
          port: @port,
          timeout: @timeout,
          logger: @logger,
          thread_pool_size: (thread_pool_size || ::Bigcommerce::Prometheus.server_thread_pool_size).to_i
        )
        @running = false
        ::PrometheusExporter::Metric::Base.default_prefix = @prefix
        setup_signal_handlers
      end

      ##
      # Start the server
      #
      def start
        @logger.info "[bigcommerce-prometheus][#{@process_name}] Starting prometheus exporter on port #{@host}:#{@port}"

        @run_thread = @server.run
        @running = true

        @logger.info "[bigcommerce-prometheus][#{@process_name}] Prometheus exporter started on #{@host}:#{@port} with #{@server.max_threads} threads"

        @server
      rescue ::StandardError => e
        @logger.error "[bigcommerce-prometheus][#{@process_name}] Failed to start exporter: #{e.message}"
        stop
      end

      ##
      # Start the server and run it until stopped
      #
      def start_until_stopped
        start
        yield
        @run_thread.join
      rescue StandardError => e
        warn "[bigcommerce-prometheus] Server crashed: #{e.message}"
        stop
      end

      ##
      # Stop the server
      #
      def stop
        @server.stop
        @run_thread.kill
        @running = false
        $stdout.puts "[bigcommerce-prometheus][#{@process_name}] Prometheus exporter cleanly shut down"
      rescue ::StandardError => e
        warn "[bigcommerce-prometheus][#{@process_name}] Failed to stop exporter: #{e.message}"
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
        @logger.info "[bigcommerce-prometheus][#{@process_name}] Registering collector #{collector&.type}"
        @server.add_type_collector(collector)
      end

      private

      ##
      # Register signal handlers
      #
      # :nocov:
      def setup_signal_handlers
        ::Signal.trap('INT', proc { stop })
        ::Signal.trap('TERM', proc { stop })
      end
      # :nocov:
    end
  end
end
