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
    # Sends the queued metrics to the collector.
    # This class has two clients
    # 1. The background thread which periodically wakes up and calls `process_queue` and is in no hurry, since nothing is waiting on it.
    # 2. A forked Resque child is about to exit and calls `flush!` on its own thread. It has very little time, since Resque's `exit!` is moments away and destroys anything still queued.
    #
    # Both go through the same `drain`, which is the point of this class.
    # The difference between them is that the flush on exit is bounded by a parametrized deadline, so that a job
    # waits a known amount on the metrics pipeline rather than however long the collector takes.
    #
    # Metric delivery is serialized on `@delivery_mutex` so only one thread is ever sending.
    #
    # A sending thread pops a message off the queue before it sends it, so the queue can be empty while a
    # request is still in flight. Without the mutex, `flush!` would find that empty queue and report itself
    # done while the background thread was still sending. Resque's `exit!` would then destroy that request.
    #
    class Delivery
      include Loggable

      # How often `flush!` retries the delivery lock while waiting for another thread to finish sending.
      LOCK_POLL_SECONDS = 0.001

      # Below this there is no point starting a request, so the remaining budget is spent reporting the drop instead.
      MINIMUM_ATTEMPT_SECONDS = 0.001

      ##
      # @param [Queue] queue a reference to the data structure that metrics are pushed onto. Whatever metrics
      #   are pushed onto this queue will be delivered.
      # @param [String] host
      # @param [Integer] port
      # @param [Float] flush_timeout total budget for a `flush!`, covering the wait for the delivery lock as well
      #   as every message it sends
      # @param [String] process_name named in every warning, so a child's warnings can be told from the parent's
      #
      def initialize(queue:, host:, port:, flush_timeout:, process_name:)
        @queue = queue
        @host = host
        @port = port
        @flush_timeout = flush_timeout
        @process_name = process_name
        @delivery_mutex = Mutex.new
      end

      ##
      # Send everything queued, with no timeout.
      #
      # The background thread's entry point. It waits for the lock rather than giving up on one, and passes no
      # deadline, because nothing is held up by it finishing late.
      #
      def process_queue
        @delivery_mutex.synchronize { drain }
      end

      ##
      # Send everything queued within the flush timeout, and log the fact if it times out with metrics still on the queue it didn't have time to deliver.
      #
      # Never raises. A lost metric must not fail the work that produced it, so an error from any delivery
      # attempt is logged and returned as `:error` rather than propagated. Exhausting the budget does not
      # raise in the first place, and returns `:timeout`.
      #
      # @return [Symbol] one of :empty, :success, :timeout, :error
      #
      def flush!
        outcome = attempt_flush_within_budget
        report_outcome(outcome)
        outcome
      end

      private

      ##
      # Run the flush on a new thread and wait for it with `join(@flush_timeout)`, so the deadline is enforced
      # from outside the delivery. If the thread has not finished before the timeout expires, it is killed and `:timeout` returned.
      #
      # `Net::HTTP`'s own timeouts do not cover a whole request and response, so they cannot bound the flush.
      # Stopping the thread at the deadline is what puts a total bound on delivering the metrics.
      #
      # A mutex held by a thread that dies is released by the VM, so stopping the thread here cannot strand the
      # delivery lock and lock out every later flush in this process.
      #
      # @return [Symbol]
      #
      def attempt_flush_within_budget
        worker = Thread.new { attempt_flush }
        return worker.value if worker.join(@flush_timeout)

        worker.kill
        :timeout
      end

      # @return [Symbol]
      def attempt_flush
        deliver_before(monotonic_now + @flush_timeout)
      rescue StandardError => e
        report("Prometheus Exporter failed to flush: #{e}")
        :error
      end

      ##
      # @param [Float] deadline monotonic clock reading to stop by
      # @return [Symbol]
      #
      def deliver_before(deadline)
        return :timeout unless acquire_delivery_lock(deadline)

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
      # @param [Float|NilClass] deadline monotonic clock reading to stop by, or nil to keep going until the queue is
      #   empty. The background thread passes nil, since it holds nothing up by waiting.
      #
      def drain(deadline = nil)
        sent = 0
        while @queue.length.to_i.positive?
          timeout = deadline && (deadline - monotonic_now)
          return :timeout if timeout && timeout < MINIMUM_ATTEMPT_SECONDS

          begin
            post_message(@queue.pop, timeout: timeout)
            sent += 1
          rescue StandardError => e
            report("dropping a message to #{uri_path('/send-metrics')}: #{e}")
            raise
          end
        end
        sent.zero? ? :empty : :success
      end

      ##
      # Post a single message.
      #
      # A flush passes the time it has left. An unhealthy collector then costs a job a known amount of time,
      # rather than waiting for `Net::HTTP` to time out.
      #
      # The background thread passes nothing, so `Net::HTTP`'s own timeouts apply.
      #
      # @param [String] message
      # @param [Float|NilClass] timeout caps each phase of this request when given
      #
      def post_message(message, timeout: nil)
        uri = uri_path('/send-metrics')
        http = ::Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = http.read_timeout = http.write_timeout = timeout if timeout
        http.start { |connection| connection.post(uri.path, message) }
      end

      ##
      # @param [String] path
      # @return [Module<URI>]
      #
      def uri_path(path)
        URI("http://#{@host}:#{@port}#{path}")
      end

      # @param [Symbol] outcome
      def report_outcome(outcome)
        return if %i[success empty].include?(outcome)

        undelivered = @queue.size
        return report_abandoned(undelivered) if undelivered.positive?

        return if outcome == :error

        report(
          "gave up after #{flush_timeout_ms}ms waiting for an in-flight send to #{uri_path('/send-metrics')}; " \
            'anything it was carrying is lost with this process'
        )
      end

      ##
      # @param [Integer] undelivered
      #
      def report_abandoned(undelivered)
        report(
          "abandoned #{undelivered} metric(s) after #{flush_timeout_ms}ms: " \
            "#{uri_path('/send-metrics')} did not accept them in time"
        )
      end

      # @return [Integer]
      def flush_timeout_ms
        (@flush_timeout * 1000).round
      end

      # @param [String] message
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
