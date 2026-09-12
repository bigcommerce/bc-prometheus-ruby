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
        # Wires `FlushOnExit` into Resque, or explains in the log why it did not.
        #
        # `resque_flush_on_exit_enabled` is read once, here. The module is prepended only when it is truthy, so being
        # in the ancestor chain is what "enabled" means and there is no flag for the child to consult. See
        # `FlushOnExit` for what the flush does and why it is needed at all.
        #
        class FlushOnExitInstaller
          ##
          # @param [PrometheusExporter::Client] client The client whose queue the child will drain
          #
          def initialize(client:)
            @client = client
          end

          ##
          # Install, unless the setting says not to, the client cannot flush, or this already ran.
          #
          # @return [void]
          #
          def install
            return if installed?
            return log_disabled unless ::Bigcommerce::Prometheus.resque_flush_on_exit_enabled
            return log_unsupported unless @client.respond_to?(:flush!)

            FlushOnExit.client = @client
            ::Resque::Worker.prepend(FlushOnExit)

            log_installed
          end

          private

          ##
          # `prepend` is idempotent, so a second install would leave the ancestor chain as it already is. What the
          # guard stops is a second boot log, and a second client replacing the one the first install chose. The
          # chain answers this without a flag to keep in sync.
          #
          # @return [Boolean]
          #
          def installed?
            defined?(::Resque::Worker) && ::Resque::Worker.ancestors.include?(FlushOnExit)
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
          # @return [void]
          #
          def log_disabled
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
          # @return [void]
          #
          def log_unsupported
            ::Bigcommerce::Prometheus.logger&.warn(
              '[bigcommerce-prometheus] resque flush on exit is enabled but the client does not support flush!.'
            )
          end

          ##
          # @return [void]
          #
          def log_installed
            ::Bigcommerce::Prometheus.logger&.info(
              '[bigcommerce-prometheus] resque flush on exit installed, so a job that pushes metrics delivers them ' \
                'before the child exits'
            )
          end
        end
      end
    end
  end
end
