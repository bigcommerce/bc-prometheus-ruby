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

      # How often `flush!` retries the delivery lock while waiting for another thread to finish sending.
      LOCK_POLL_SECONDS = 0.001

      # Below this there is no point starting a request, so the remaining budget is spent reporting the drop instead.
      MINIMUM_ATTEMPT_SECONDS = 0.001

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
        @write_timeout = ::Bigcommerce::Prometheus.client_write_timeout
        @flush_timeout = ::Bigcommerce::Prometheus.client_flush_timeout
        @delivery_mutex = Mutex.new
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
      # Serialised so that only one thread is ever delivering. Two callers reach here, the background worker thread and
      # `flush!` on the caller's own thread, and without the lock either could return while the other still had a
      # message in flight. It also closes a hang: both threads can see a length of one, both call `pop`, and the loser
      # blocks on an empty queue forever.
      #
      def process_queue
        @delivery_mutex.synchronize { drain }
      end

      ##
      # Deliver anything queued, on the calling thread, and return once it has been sent.
      #
      # `send_json` only queues; delivery happens on a background thread that wakes every `client_thread_sleep`
      # seconds. A process that is about to exit does not get that far, so anything pushed shortly before exit is
      # discarded with it. Callers that are about to exit should flush.
      #
      # Returns once everything is delivered, including anything the background thread had already taken off the queue
      # and was part way through sending. An empty queue is not the same as an empty wire, so this deliberately does not
      # short circuit on one: the message the worker thread popped a microsecond ago is exactly the one about to be lost.
      #
      # Bounded by `client_flush_timeout`, covering the wait for the delivery lock and the requests themselves. The
      # caller is normally about to exit and is holding up real work while it waits, so an unhealthy collector must cost
      # it a known amount rather than however long the network takes to give up. Past the deadline the observations are
      # abandoned and reported, because availability of the work matters more than completeness of its metrics.
      #
      # A caller that pushed nothing pays one uncontended lock acquire, since a process that never pushed never started
      # a worker thread. Never raises: metric delivery must not take down the work that produced the metric.
      #
      def flush!
        deliver_before(monotonic_now + @flush_timeout)
      rescue StandardError => e
        report("Prometheus Exporter failed to flush: #{e}")
      ensure
        report_undelivered
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
      # Both mutexes are reset for a rarer case. If the fork lands while another thread holds one, the child inherits a
      # locked mutex with no owner, and blocks forever the first time it needs it. For `@mutex` that is the first push,
      # and for `@delivery_mutex` it is the first delivery.
      #
      def reset_after_fork!
        @queue = Queue.new
        @worker_thread = nil
        @mutex = Mutex.new
        @delivery_mutex = Mutex.new
        @socket = nil
        @socket_started = nil
        @socket_pid = nil
      end

      private

      ##
      # Take the delivery lock, send what is queued, and give the lock back. Gives up rather than queueing behind a
      # delivery that will not finish in time.
      #
      # @param [Float] deadline monotonic clock reading to stop by
      #
      def deliver_before(deadline)
        return unless acquire_delivery_lock(deadline)

        begin
          drain(deadline)
        ensure
          @delivery_mutex.unlock
        end
      end

      ##
      # @param [Float] deadline
      # @return [Boolean] whether the lock was taken
      #
      def acquire_delivery_lock(deadline)
        until @delivery_mutex.try_lock
          return false if monotonic_now >= deadline

          sleep LOCK_POLL_SECONDS
        end
        true
      end

      ##
      # Send queued messages one at a time. The caller owns the delivery lock.
      #
      # @param [Float|NilClass] deadline monotonic clock reading to stop by, or nil to keep going until the queue is
      #   empty. The background thread passes nil, since it holds nothing up by waiting.
      #
      def drain(deadline = nil)
        while @queue.length.to_i.positive?
          timeout = deadline && (deadline - monotonic_now)
          break if timeout && timeout < MINIMUM_ATTEMPT_SECONDS

          begin
            post_message(@queue.pop, timeout: timeout)
          rescue StandardError => e
            report("dropping a message to #{uri_path('/send-metrics')}: #{e}")
            raise
          end
        end
      end

      ##
      # Post a single message with bounded timeouts.
      #
      # `Net::HTTP` defaults every timeout to 60 seconds. That is survivable on the background thread and is not
      # survivable inline in a job, where an unhealthy collector would stall every unit of work. The collector is
      # normally on localhost, so the defaults here are short, and an inline flush overrides them with whatever is left
      # of its budget.
      #
      # @param [String] message
      # @param [Float|NilClass] timeout overrides all three phases when given
      #
      def post_message(message, timeout: nil)
        uri = uri_path('/send-metrics')
        http = ::Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = timeout || @open_timeout
        http.read_timeout = timeout || @read_timeout
        http.write_timeout = timeout || @write_timeout
        http.start { |connection| connection.post(uri.path, message) }
      end

      ##
      # Say so when observations are abandoned, rather than letting them disappear silently. This is the only signal
      # that a collector outage is costing metrics, since the metric that would have reported it is the one being lost.
      #
      def report_undelivered
        undelivered = @queue.size
        return if undelivered.zero?

        report(
          "abandoned #{undelivered} metric(s) after #{(@flush_timeout * 1000).round}ms: " \
          "#{uri_path('/send-metrics')} did not accept them in time"
        )
      end

      ##
      # Warn, then push the line out of the process.
      #
      # Callers of `flush!` are usually about to be torn down by `exit!`, which runs no handlers and flushes no
      # buffers. A warning sitting in a buffered STDOUT is destroyed along with the metric it was reporting, so the
      # buffers are emptied here rather than left to an exit that will never come.
      #
      # @param [String] message
      #
      def report(message)
        logger.warn "[bigcommerce-prometheus][#{@process_name}] #{message}"
        $stdout.flush
        $stderr.flush
      rescue StandardError
        nil
      end

      # @return [Float]
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
