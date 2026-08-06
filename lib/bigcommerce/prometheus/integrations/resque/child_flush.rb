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
        # Deliver a forked child's observations before Resque tears it down.
        #
        # Resque runs each job in a child that ends with `exit!`, which runs no at_exit handlers and does not wait for
        # threads. The client only queues on push and delivers on a background thread that wakes every
        # `client_thread_sleep` seconds, so anything a job pushes is normally destroyed with the child. Draining on the
        # calling thread before the job returns is the only way an in-child observation reliably arrives.
        #
        # This is deliberately not the approach taken for the `resque_job` histograms, which are recorded in the parent
        # precisely to avoid paying anything per job. It exists for the observations application code pushes from
        # inside its own jobs, which the gem cannot move anywhere else.
        #
        # Cost is one request to the local collector, and nothing at all when the job pushed no metrics. It depends on
        # the child having been given a clean queue at fork time; without that the child would synchronously send the
        # parent's backlog too, which is the latency problem this design exists to avoid.
        #
        # Disable with PROMETHEUS_RESQUE_CHILD_FLUSH_ENABLED=0.
        #
        module ChildFlush
          ##
          # Wraps `Resque::Worker#perform`, which is the in-child entry point when the worker forks per job. Guarded on
          # `fork_per_job?` so a non-forking worker keeps the asynchronous path, since it is long-lived and its
          # background thread drains on its own.
          #
          def perform(job, &block)
            super
          ensure
            ::Bigcommerce::Prometheus.client.flush! if fork_per_job?
          end
        end
      end
    end
  end
end
