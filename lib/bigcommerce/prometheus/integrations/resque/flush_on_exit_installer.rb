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
        # Wires `FlushOnExit` into Resque, or logs why it did not.
        #
        # Reads `resque_flush_on_exit_enabled` once, at boot, and prepends `FlushOnExit` to `Resque::Worker` only
        # when it is true. Nothing reads the setting again. A forked child either finds the module in its ancestor
        # chain and flushes, or does not find it and returns as it always did.
        #
        # See `FlushOnExit` for what the flush does and why it is needed at all.
        #
        class FlushOnExitInstaller
          ##
          # @param [PrometheusExporter::Client] client The client whose queue the child will drain
          #
          def initialize(client:)
            @client = client
          end

          ##
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
          # @return [Boolean]
          #
          def installed?
            defined?(::Resque::Worker) && ::Resque::Worker.ancestors.include?(FlushOnExit)
          end

          ##
          # @return [void]
          #
          def log_disabled
            ::Bigcommerce::Prometheus.logger&.info('[bigcommerce-prometheus] resque flush on exit is disabled')
          end

          ##
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
            ::Bigcommerce::Prometheus.logger&.info('[bigcommerce-prometheus] resque flush on exit installed.')
          end
        end
      end
    end
  end
end
