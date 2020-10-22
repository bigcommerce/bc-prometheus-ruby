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
    # Client implementation for Prometheus
    #
    class Client < ::PrometheusExporter::Client
      include Singleton
      include Loggable

      ##
      # @param [String] host
      # @param [Integer] port
      # @param [Integer] max_queue_size
      # @param [Integer|Float] thread_sleep
      # @param [Hash] custom_labels
      # @param [String] process_name
      #
      def initialize(host: nil, port: nil, max_queue_size: nil, thread_sleep: nil, custom_labels: nil, process_name: nil)
        super(
          host: host || Bigcommerce::Prometheus.server_host,
          port: port || Bigcommerce::Prometheus.server_port,
          max_queue_size: max_queue_size || Bigcommerce::Prometheus.client_max_queue_size,
          thread_sleep: thread_sleep || Bigcommerce::Prometheus.client_thread_sleep,
          custom_labels: custom_labels || Bigcommerce::Prometheus.client_custom_labels
        )
        PrometheusExporter::Client.default = self
        @process_name = process_name || ::Bigcommerce::Prometheus.process_name
      end

      ##
      # Patch the worker loop to make it more resilient
      #
      def worker_loop
        close_socket_if_old!
        process_queue
      rescue StandardError => e
        logger.warn "[bigcommerce-prometheus][#{@process_name}] Prometheus client failed to send message to #{@host}:#{@port} #{e} - #{e.backtrace[0..5].join("\n")}"
      end

      ##
      # Patch the close socket command to handle when @socket_started is nil
      #
      def close_socket_if_old!
        close_socket! if @socket && ((@socket_started.to_i + MAX_SOCKET_AGE) < Time.now.to_f)
      end

      ##
      # @param [String] path
      # @return [Module<URI>]
      #
      def uri_path(path)
        URI("http://#{@host}:#{@port}#{path}")
      end

      ##
      # Process the current queue and flush to the collector
      #
      def process_queue
        while @queue.length.to_i.positive?
          begin
            message = @queue.pop
            Net::HTTP.post(uri_path('/send-metrics'), message)
          rescue StandardError => e
            logger.warn "[bigcommerce-prometheus][#{@process_name}] Prometheus Exporter is dropping a message tp #{uri_path('/send-metrics')}: #{e}"
            raise
          end
        end
      end
    end
  end
end
