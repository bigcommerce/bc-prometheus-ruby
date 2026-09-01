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
    module Integrations
      class Resque
        ##
        # Give a forked child a clean client, before anything in that child can use the one it inherited.
        #
        # The client is a singleton, so `fork` hands the child a copy of the parent's outbound queue while leaving the
        # thread that would drain it behind. Everything the parent had not yet sent therefore has to be re-sent by the
        # child, one request each, before it reaches its own observation, and Resque's `exit!` arrives long before that
        # finishes. Discarding the copy is safe: the parent still holds the originals and sends them on its own
        # schedule.
        #
        # Wraps `Resque::Worker#perform` rather than registering a `Resque.after_fork` hook. A hook works, but
        # `Resque.after_fork` appends and `Resque::Worker#run_hook` runs hooks in registration order, so an application
        # hook that records a metric and happened to be registered first would have its observation enqueued here and
        # then discarded. `Worker#perform` is what runs those hooks, so wrapping it puts the reset ahead of all of them
        # whatever order anyone registers in.
        #
        module ForkReset
          class << self
            ##
            # The client to reset. Held here rather than captured in a closure so the flush half of this integration
            # can be handed the same object. See `Integrations::Resque.start`.
            #
            # @return [PrometheusExporter::Client]
            #
            attr_accessor :client

            ##
            # The process that installed this. Any other process reaching `#perform` is a forked child.
            #
            # @return [Integer]
            #
            attr_accessor :installed_in_pid

            ##
            # Discard the inherited queue, if and only if this is a forked child.
            #
            # `fork_per_job?` is not enough on its own. `Worker#perform` also runs in the long-lived parent, both for a
            # worker started with FORK_PER_JOB=false and through the deprecated `Worker#process`, and a reset there
            # would throw away the queue the parent is still responsible for sending. A changed pid is the fact that
            # actually distinguishes the two, and it is the same test the upstream client applies to its own socket.
            #
            def reset_if_forked
              return if installed_in_pid.nil? || Process.pid == installed_in_pid
              return unless client.respond_to?(:reset_after_fork!)

              client.reset_after_fork!
            end
          end

          ##
          # @param [Resque::Job] job
          #
          def perform(job, &block)
            ForkReset.reset_if_forked
            super
          end
        end
      end
    end
  end
end
