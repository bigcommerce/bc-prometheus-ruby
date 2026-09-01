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
        class << self
          ##
          # Start the resque integration
          #
          def start(client: nil)
            resque_client = client || ::Bigcommerce::Prometheus.client

            # Installed ahead of the collectors, and the reset installed whatever the flag below says. Together these are
            # the safety net for every observation pushed from a forked child, so they must not depend on the collectors
            # that follow starting successfully. The reset is also what keeps the flush cheap: without it a child would
            # synchronously re-send the parent's backlog before reaching its own message.
            #
            # Both wrap `Resque::Worker#perform`. Which one is prepended first does not matter, since the reset runs
            # before `super` and the flush after it either way.
            install_fork_reset(resque_client)
            install_fork_exit_flush(resque_client)

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

          private

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
          def install_fork_reset(client)
            ForkReset.client = client
            ForkReset.installed_in_pid = Process.pid
            ::Resque::Worker.prepend(ForkReset)
          end

          ##
          # Deliver a forked child's own observations before Resque's `exit!` discards them.
          #
          # Two hooks, because the decision and the delivery happen in different processes. `before_fork` runs in the
          # parent, so that is where `resque_fork_exit_flush_enabled` is resolved, and the child inherits the answer through
          # the fork itself. `Resque::Worker#perform` is the only in-child boundary that runs after the job body, and it
          # is a method rather than a hook, hence the prepend.
          #
          # Resolving per fork rather than once here is what lets a caller pass a callable and change its mind at
          # runtime without a restart. Nothing in the child ever evaluates it.
          #
          # Idempotent. Resque appends `before_fork` hooks rather than replacing them, so a second call would otherwise
          # register a second hook.
          #
          # Takes the client rather than reaching for the singleton at flush time, so that the queue drained here is the
          # one `install_fork_reset` cleared. A caller passing `client:` would otherwise get two different queues.
          #
          # @param [PrometheusExporter::Client] client
          #
          def install_fork_exit_flush(client)
            return if @fork_exit_flush_installed
            return log_fork_exit_flush_off unless ::Bigcommerce::Prometheus.resque_fork_exit_flush_enabled

            # Asked once here rather than only per job. `ForkExitFlush.flush` checks too, but deliberately says
            # nothing, because it runs inside an `ensure` where raising would replace whatever the job was
            # already raising. That leaves a caller who passes an unsupported client with no signal at all.
            # Boot is the one place a complaint is safe. It is the long-lived parent, once, well away from any
            # job's exception handling.
            return log_fork_exit_flush_unsupported unless client.respond_to?(:flush!)

            ForkExitFlush.client = client
            ::Resque::Worker.prepend(ForkExitFlush)
            ::Resque.before_fork { |job| ForkExitFlush.enabled = resolve_fork_exit_flush(job) }
            @fork_exit_flush_installed = true
            log_fork_exit_flush_installed
          end

          ##
          # Resolve whether this child should flush. Runs in the parent, before the fork.
          #
          # `resque_fork_exit_flush_enabled` is either a plain value or something callable. A callable is handed the
          # `Resque::Job` when it accepts one, so a caller can decide per job as well as per process.
          # `JobPayload.for(job).job_class` unwraps ActiveJob's payload if the caller wants the real class name.
          #
          # Never raises. This is a `before_fork` hook, so an exception here propagates into `perform_with_fork` and
          # takes down job processing. A flaky feature flag must not be able to stop a worker, so a failure means no
          # flush, which is the asynchronous behaviour callers had before this existed.
          #
          # @param [Resque::Job] job
          # @return [Boolean]
          #
          def resolve_fork_exit_flush(job)
            setting = ::Bigcommerce::Prometheus.resque_fork_exit_flush_enabled
            return !!setting unless setting.respond_to?(:call)

            # Procs answer `arity` themselves. An object with a `#call` method does not, and asking `method(:call).arity`
            # of a proc reports `Proc#call(*args)` as -1, which would hand a job to a callable that takes none. So ask
            # the object first and fall back to its method.
            arity = setting.respond_to?(:arity) ? setting.arity : setting.method(:call).arity

            !!(arity.zero? ? setting.call : setting.call(job))
          rescue StandardError => e
            ::Bigcommerce::Prometheus.logger&.warn(
              "[bigcommerce-prometheus] resque fork exit flush check failed, not flushing this job: #{e}"
            )
            false
          end

          ##
          # Hedged deliberately. The child starts a delivery thread on the first push, and upstream runs its loop
          # once before sleeping. A job that keeps working after pushing often does get its metric out. What the
          # flush adds is reliability rather than delivery.
          #
          # Info rather than warn: this is the default, and it is what every caller already had. A warning on every
          # worker boot of every service would only teach people to ignore warnings. Said out loud anyway, because a
          # metric that never arrives is otherwise indistinguishable from one that was never recorded.
          #
          def log_fork_exit_flush_off
            ::Bigcommerce::Prometheus.logger&.info(
              '[bigcommerce-prometheus] resque fork exit flush is off, so metrics recorded inside a job are only ' \
              'delivered if the background thread runs before the child exits; set ' \
              'PROMETHEUS_RESQUE_FORK_EXIT_FLUSH_ENABLED=1 to deliver them reliably, at the cost of one request ' \
              'per observation a job records'
            )
          end

          ##
          # Warn rather than info. Unlike the setting being off, this is a configuration mistake: the caller asked
          # for the flush and cannot have it.
          #
          def log_fork_exit_flush_unsupported
            ::Bigcommerce::Prometheus.logger&.warn(
              '[bigcommerce-prometheus] resque fork exit flush is enabled but the client does not support flush!, ' \
              'so nothing is flushed before a child exits; metrics recorded inside a job are only delivered if ' \
              'the background thread runs first'
            )
          end

          def log_fork_exit_flush_installed
            dynamic = ::Bigcommerce::Prometheus.resque_fork_exit_flush_enabled.respond_to?(:call)
            resolution = dynamic ? 'resolved in the parent before every fork' : 'enabled for every job'

            ::Bigcommerce::Prometheus.logger&.info(
              "[bigcommerce-prometheus] resque fork exit flush installed, #{resolution}; a job that pushes metrics " \
              'delivers them before the child exits'
            )
          end
        end
      end
    end
  end
end
