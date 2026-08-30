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
    # Queueing and registration are the superclass's. Everything about getting a queued message to the collector
    # belongs to `Delivery`, which this hands its own queue to and rebuilds whenever that queue is replaced.
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
        @delivery = build_delivery
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
      # @param [String] str
      def send(str)
        return unless Bigcommerce::Prometheus.enabled

        super
      end

      ##
      # Process the current queue and flush to the collector
      #
      # Overridden because the superclass streams onto a long-lived socket, which this gem stopped doing. Called by
      # the background worker thread only.
      #
      def process_queue
        @delivery.process_queue
      end

      ##
      # Deliver what is queued before the caller stops being able to.
      #
      # @return [Symbol] one of :empty, :success, :timeout, :error
      #
      def flush!
        @delivery.flush!
      end

      ##
      # Discard the state a forked child inherited from its parent.
      #
      # The client is a singleton, so `fork` hands the child a copy of the parent's outbound queue
      # Anything still queued in the parent therefore has to be re-sent by the child,
      #
      # The mutex is reset for a rarer case. If the fork happens while another thread holds the mutex, the child inherits a
      # locked mutex and can never claim it.
      #
      # `Delivery` is rebuilt last, and for both reasons at once. It has to be given the new queue, and its own
      # delivery lock may have been held by a thread that did not survive the fork.
      #
      def reset_after_fork!
        @queue = Queue.new
        @worker_thread = nil
        @mutex = Mutex.new
        @socket = nil
        @socket_started = nil
        @socket_pid = nil
        @delivery = build_delivery
      end

      private

      ##
      # Whatever is queued now, and the settings to deliver it under.
      #
      # Built rather than assigned once, so `reset_after_fork!` can replace it wholesale. That is how a child stops
      # sharing a queue, and a delivery lock, with the parent it forked from.
      #
      # @return [Bigcommerce::Prometheus::Delivery]
      #
      def build_delivery
        Delivery.new(
          queue: @queue,
          host: @host,
          port: @port,
          open_timeout: ::Bigcommerce::Prometheus.client_open_timeout,
          read_timeout: ::Bigcommerce::Prometheus.client_read_timeout,
          write_timeout: ::Bigcommerce::Prometheus.client_write_timeout,
          flush_timeout: ::Bigcommerce::Prometheus.client_flush_timeout,
          process_name: @process_name
        )
      end
    end
  end
end
