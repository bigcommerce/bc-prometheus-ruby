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
            FlushOnExitInstaller.new(client: resque_client).install

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
          #
          # Whether a client can reset itself is fixed when it is passed in, so it is settled once at install
          # rather than on every job. This matches what FlushOnExitInstaller does with `flush!`.
          # A client that cannot is left unwrapped. Prepending anyway would put a module in the ancestors of
          # `Resque::Worker` that advertises a reset it can never perform.
          #
          # @param [PrometheusExporter::Client] client the client a child will be given.
          #
          def install_fork_reset(client)
            return log_reset_unsupported unless client.respond_to?(:reset_after_fork!)

            ForkReset.client = client
            ForkReset.installed_in_pid = Process.pid
            ::Resque::Worker.prepend(ForkReset)
          end

          ##
          # @return [void]
          #
          def log_reset_unsupported
            ::Bigcommerce::Prometheus.logger&.warn(
              '[bigcommerce-prometheus] resque fork reset skipped: the client does not support reset_after_fork!.'
            )
          end
        end
      end
    end
  end
end
