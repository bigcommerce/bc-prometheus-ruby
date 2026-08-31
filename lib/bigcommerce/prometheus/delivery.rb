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
    # Take what the client has queued and get it to the collector.
    #
    # Two callers reach here and they want different things. The client's background thread calls `process_queue` and
    # is in no hurry, since nothing is waiting on it. A forked Resque child calls `flush!` on its own thread and has
    # very little time, since Resque's `exit!` is moments away and destroys anything still queued.
    #
    # Both go through the same `drain`, which is the point of this class. The difference between them is one argument,
    # a deadline, rather than two delivery paths that could drift apart.
    #
    # Serialised on `@delivery_mutex` so only one thread is ever delivering. Without it either caller could return
    # while the other still had a message in flight, which for the child means returning just in time to be killed.
    #
    class Delivery
      include Loggable

      # How often `flush!` retries the delivery lock while waiting for another thread to finish sending.
      LOCK_POLL_SECONDS = 0.001

      # Below this there is no point starting a request, so the remaining budget is spent reporting the drop instead.
      MINIMUM_ATTEMPT_SECONDS = 0.001

      ##
      # @param [Queue] queue the client's own queue, not a copy. Whatever the client pushes onto after this is
      #   constructed is what gets delivered, which is why a fork replaces the client's queue and this object together.
      # @param [String] host
      # @param [Integer] port
      # @param [Float] flush_timeout total budget for a `flush!`, across every message it sends
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
      # Send everything queued, taking as long as it takes.
      #
      # The background thread's entry point. It waits for the lock rather than giving up on one, and passes no
      # deadline, because nothing is held up by it finishing late.
      #
      def process_queue
        @delivery_mutex.synchronize { drain }
      end

      ##
      # Send everything queued within the flush timeout, and say so if anything is left.
      #
      # Never raises. A lost metric must not fail the work that produced it, so everything is reported and swallowed.
      #
      # @return [Symbol] one of :empty, :success, :timeout, :error
      #
      def flush!
        outcome = attempt_flush
        report_outcome(outcome)
        outcome
      end

      private

      # @return [Symbol]
      def attempt_flush
        deliver_before(monotonic_now + @flush_timeout)
      rescue StandardError => e
        report("Prometheus Exporter failed to flush: #{e}")
        :error
      end

      ##
      # Take the delivery lock, send what is queued, and give the lock back. Gives up rather than queueing behind a
      # delivery that will not finish in time.
      #
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
      # A flush passes the time it has left. An unhealthy collector then costs a job a known amount,
      # rather than however long the network takes to give up.
      #
      # The background thread passes nothing, so `Net::HTTP`'s own 60 second defaults apply. Nothing waits
      # on that thread, and those are the timeouts this gem has always delivered under.
      #
      # @param [String] message
      # @param [Float|NilClass] timeout bounds all three phases when given
      #
      def post_message(message, timeout: nil)
        uri = uri_path('/send-metrics')
        http = ::Net::HTTP.new(uri.host, uri.port)
        if timeout
          http.open_timeout = timeout
          http.read_timeout = timeout
          http.write_timeout = timeout
        end
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

        # `drain` reports the one message it was carrying when it failed, and re-raises. Anything still behind that
        # message is reported above, since it is just as lost. There is nothing left to say once the queue is empty:
        # nothing was in flight, so the message below would be a false claim.
        return if outcome == :error

        # Nothing queued, and still not a success. The background thread had already taken the message off the queue
        # and was sending it, which is why the lock could not be acquired. `@queue.size` cannot see that message, so
        # counting the queue alone would report this as nothing lost, in the one case where something is.
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
