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
      ##
      # Plugin for resque
      #
      class Resque
        ##
        # Start the resque integration
        #
        def self.start(client: nil)
          resque_client = client || ::Bigcommerce::Prometheus.client

          # Installed ahead of the collectors, and the reset installed whatever the flag below says. Together these are
          # the safety net for every observation pushed from a forked child, so they must not depend on the collectors
          # that follow starting successfully. The reset is also what keeps the flush cheap: without it a child would
          # synchronously re-send the parent's backlog before reaching its own message.
          #
          # Both wrap `Resque::Worker#perform`. Which one is prepended first does not matter, since the reset runs
          # before `super` and the flush after it either way.
          install_fork_reset(resque_client)
          install_child_flush(resque_client)

          ::PrometheusExporter::Instrumentation::Process.start(
            client: resque_client,
            type: ::Bigcommerce::Prometheus.resque_process_label
          )
          ::Bigcommerce::Prometheus::Collectors::Resque.start(
            client: resque_client,
            frequency: ::Bigcommerce::Prometheus.resque_collection_frequency
          )
          ::Bigcommerce::Prometheus::Integrations::Resque::JobMetrics.start(
            client: resque_client
          )
        end

        ##
        # Hand each forked child a clean client instead of a copy of whatever the parent had not yet drained.
        #
        # Installed whatever the per-job flush setting is: Collectors::Resque pushes from the parent every 30 seconds,
        # so a child can inherit queued messages either way. See `ForkReset` for why this wraps `Worker#perform`
        # instead of registering an after_fork hook.
        #
        # The pid is recorded here because this runs in the worker parent, which makes it the reading every forked
        # child differs from.
        #
        # Idempotent. `Module#prepend` ignores a module already in the ancestors, and a second call assigns the same
        # two values.
        #
        # @param [PrometheusExporter::Client] client
        #
        def self.install_fork_reset(client)
          ForkReset.client = client
          ForkReset.installed_in_pid = Process.pid
          ::Resque::Worker.prepend(ForkReset)
        end
        private_class_method :install_fork_reset

        ##
        # Deliver a forked child's own observations before Resque's `exit!` discards them.
        #
        # Prepends rather than using a Resque hook because Resque has no in-child hook that runs after the job body.
        # `Resque::Worker#perform` is that boundary.
        #
        # Idempotent, since a repeated prepend of an already-prepended module is a no-op but the guard keeps the
        # intent explicit.
        #
        # Takes the client rather than reaching for the singleton at flush time, so that the queue drained here is the
        # one `install_fork_reset` cleared. A caller passing `client:` would otherwise get two different queues.
        #
        # @param [PrometheusExporter::Client] client
        #
        def self.install_child_flush(client)
          return if @child_flush_installed

          unless ::Bigcommerce::Prometheus.resque_child_flush_enabled
            # Info rather than warn: this is the default, and it is the behaviour every caller already had. A warning
            # on every worker boot of every service would only teach people to ignore warnings. Said out loud anyway,
            # because a metric that never arrives is otherwise indistinguishable from one that was never recorded.
            ::Bigcommerce::Prometheus.logger&.info(
              '[bigcommerce-prometheus] resque child metric flush is off, so metrics recorded inside a job are not ' \
              'delivered; set PROMETHEUS_RESQUE_CHILD_FLUSH_ENABLED=1 to deliver them, at the cost of one request ' \
              'per observation a job records'
            )
            return
          end

          ChildFlush.client = client
          ::Resque::Worker.prepend(ChildFlush)
          @child_flush_installed = true
          ::Bigcommerce::Prometheus.logger&.info(
            '[bigcommerce-prometheus] resque child metric flush installed; a job that pushes metrics delivers them ' \
            'before the child exits'
          )
        end
        private_class_method :install_child_flush
      end
    end
  end
end
