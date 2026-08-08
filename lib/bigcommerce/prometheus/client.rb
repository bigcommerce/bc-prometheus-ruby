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
        @open_timeout = ::Bigcommerce::Prometheus.client_open_timeout
        @read_timeout = ::Bigcommerce::Prometheus.client_read_timeout
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
      # @param [String] str
      def send(str)
        return unless Bigcommerce::Prometheus.enabled

        super
      end

      ##
      # Process the current queue and flush to the collector
      #
      def process_queue
        while @queue.length.to_i.positive?
          begin
            message = @queue.pop
            post_message(message)
          rescue StandardError => e
            logger.warn "[bigcommerce-prometheus][#{@process_name}] Prometheus Exporter is dropping a message to #{uri_path('/send-metrics')}: #{e}"
            raise
          end
        end
      end

      ##
      # Deliver anything queued, on the calling thread, and return once it has been sent.
      #
      # `send_json` only queues; delivery happens on a background thread that wakes every `client_thread_sleep`
      # seconds. A process that is about to exit does not get that far, so anything pushed shortly before exit is
      # discarded with it. Callers that are about to exit should flush.
      #
      # A no-op when nothing is queued, so callers that never push pay nothing. Never raises: metric delivery must not
      # take down the work that produced the metric.
      #
      def flush!
        return if @queue.empty?

        process_queue
      rescue StandardError => e
        logger.warn "[bigcommerce-prometheus][#{@process_name}] Prometheus Exporter failed to flush: #{e}"
      end

      ##
      # Discard the state a forked child inherited from its parent.
      #
      # The client is a singleton, so `fork` hands the child a copy of the parent's outbound queue while leaving the
      # thread that would drain it behind. Anything still queued in the parent therefore has to be re-sent by the child,
      # one request each, before the child reaches its own observation — and a Resque child is torn down by `exit!` long
      # before that finishes. Discarding the copy is safe: the parent still holds the originals and sends them on its
      # own schedule.
      #
      # The mutex is reset for a rarer case. If the fork lands while another thread holds it, the child inherits a
      # locked mutex with no owner and deadlocks on its first push.
      #
      def reset_after_fork!
        @queue = Queue.new
        @worker_thread = nil
        @mutex = Mutex.new
        @socket = nil
        @socket_started = nil
        @socket_pid = nil
      end

      private

      ##
      # Post a single message with bounded timeouts.
      #
      # `Net::HTTP.post` defaults to a 60 second open timeout. That is survivable on the background thread and is not
      # survivable inline in a job, where an unreachable exporter would stall every unit of work for a minute. The
      # collector is normally on localhost, so the defaults here are short.
      #
      # @param [String] message
      #
      def post_message(message)
        uri = uri_path('/send-metrics')
        http = ::Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
        http.start { |connection| connection.post(uri.path, message) }
      end
    end
  end
end
