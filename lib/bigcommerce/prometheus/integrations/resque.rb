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

            install_fork_reset(resque_client)
            install_flush_on_exit(resque_client)

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
          # Ensure the forked child starts with an empty metrics queue.
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
          # @param [PrometheusExporter::Client] client
          #
          def install_flush_on_exit(client)
            return if @flush_on_exit_installed
            return log_flush_on_exit_off unless flush_on_exit_possible?

            return log_flush_on_exit_unsupported unless client.respond_to?(:flush!)

            FlushOnExit.client = client

            ::Resque::Worker.prepend(FlushOnExit)

            # This block runs in the parent, before each fork.
            # `resque_flush_on_exit_enabled` can be a callable which is evaluated here rather than once at boot.
            # This means that flushing on exit can be enabled and disabled without a restart of the worker.
            ::Resque.before_fork { |job| FlushOnExit.enabled = should_flush_on_exit?(job) }

            @flush_on_exit_installed = true
            log_flush_on_exit_installed
          end

          ##
          # Whether to install FlushOnExit.
          # ::Bigcommerce::Prometheus.resque_flush_on_exit_enabled can be one of three values
          # 1. false: Prometheus metrics will never be flushed at exit
          # 2. true: Prometheus metrics will be flushed at exit
          # 3. callable: Whether Prometheus metrics will be flushed at exit is decided on a job by job basis depending
          #   on the result of the callable. This is useful for a LaunchDarkly experiment evaluation.
          # @return [Boolean]
          #
          def flush_on_exit_possible?
            setting = ::Bigcommerce::Prometheus.resque_flush_on_exit_enabled
            setting.respond_to?(:call) || !!setting
          end

          ##
          # Resolve whether this child should flush. Runs in the parent, before the fork.
          #
          # `resque_flush_on_exit_enabled` is either a plain value or a callable. A callable is handed the
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
          def should_flush_on_exit?(job)
            setting = ::Bigcommerce::Prometheus.resque_flush_on_exit_enabled
            return !!setting unless setting.respond_to?(:call)

            # Procs answer `arity` themselves. An object with a `#call` method does not, and asking `method(:call).arity`
            # of a proc reports `Proc#call(*args)` as -1, which would hand a job to a callable that takes none. So ask
            # the object first and fall back to its method.
            arity = setting.respond_to?(:arity) ? setting.arity : setting.method(:call).arity

            !!(arity.zero? ? setting.call : setting.call(job))
          rescue StandardError => e
            ::Bigcommerce::Prometheus.logger&.warn(
              "[bigcommerce-prometheus] resque flush on exit check failed, not flushing this job: #{e}"
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
          def log_flush_on_exit_off
            ::Bigcommerce::Prometheus.logger&.info(
              '[bigcommerce-prometheus] resque flush on exit is off, so metrics recorded inside a job are only ' \
                'delivered if the background thread runs before the child exits; set ' \
                'PROMETHEUS_RESQUE_FLUSH_ON_EXIT_ENABLED=1 to deliver them reliably, at the cost of one request ' \
                'per observation a job records'
            )
          end

          ##
          # Warn rather than info. Unlike the setting being off, this is a configuration mistake: the caller asked
          # for the flush, but it passed a client which doesn't implement flush!.
          #
          def log_flush_on_exit_unsupported
            ::Bigcommerce::Prometheus.logger&.warn(
              '[bigcommerce-prometheus] resque flush on exit is enabled but the client does not support flush!.'
            )
          end

          def log_flush_on_exit_installed
            dynamic = ::Bigcommerce::Prometheus.resque_flush_on_exit_enabled.respond_to?(:call)
            resolution = dynamic ? 'resolved in the parent before every fork' : 'enabled for every job'

            ::Bigcommerce::Prometheus.logger&.info(
              "[bigcommerce-prometheus] resque flush on exit installed, #{resolution}; a job that pushes metrics " \
                'delivers them before the child exits'
            )
          end
        end
      end
    end
  end
end
