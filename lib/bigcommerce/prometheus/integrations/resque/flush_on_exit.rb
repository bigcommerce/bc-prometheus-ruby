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
        # Deliver a forked child's observations before the child process exits to ensure queued metrics do not get dropped.
        #
        # Resque runs each job in a child that ends with `exit!`, which runs no at_exit handlers and does not wait for
        # threads. So despite the name, this is not an at_exit hook. It wraps `Resque::Worker#perform` and flushes
        # from its `ensure`, which is the last point the child still runs code.
        #
        # Recording a metric does not send it. Delivery happens on a background thread, and whatever is still queued when
        # the child exits does not get delivered.
        #
        # The background delivery thread attempts a delivery as soon as it starts, then sleeps `client_thread_sleep`
        # between passes. A job that keeps working after pushing usually stays alive long enough for one of those
        # passes to send what it queued.
        # However, this is a race between the metrics delivery thread and the work of the job.
        # If for example, a metric is pushed to the queue, and the job immediately exits, it will not have a chance to be delivered and be lost.
        # Flushing the metrics on the calling thread before the job returns ensures the metrics get delivered rather than it being
        # a race to publish them before the child exits.
        #
        # Cost is one request to the local collector per observation still queued, and nothing at all when the job
        # pushed no metrics. `Delivery#drain` posts each message separately, which is how this gem has delivered since it
        # stopped using the upstream chunked socket.
        #
        # The flush is opt-in as it adds additional latency to the job by sending the remaining metrics prior to exit, albeit bounded by an aggressive timeout.
        # The opt-in mechanism is via the env var PROMETHEUS_RESQUE_FLUSH_ON_EXIT_ENABLED which in turn sets `resque_flush_on_exit_enabled`
        # As with the other settings, it can be overridden by an assignment.
        # `FlushOnExitInstaller` reads the setting once at boot and prepends this module only when it is true.
        # This module carries no flag of its own and never reads the setting.
        #
        module FlushOnExit
          class << self
            ##
            # The client to drain. The same object `ForkReset` was handed, so what is delivered here is the queue the
            # child was given at fork time.
            #
            # @return [PrometheusExporter::Client]
            #
            attr_accessor :client

            def flush
              client.flush! if client.respond_to?(:flush!)
            end
          end

          ##
          # Wraps `Resque::Worker#perform`, which is the in-child entry point when the worker forks per job. Guarded on
          # `fork_per_job?` so a non-forking worker keeps the asynchronous path, since it is long-lived and its
          # background thread drains on its own.
          #
          def perform(job, &block)
            super
          ensure
            FlushOnExit.flush if fork_per_job?
          end
        end
      end
    end
  end
end
