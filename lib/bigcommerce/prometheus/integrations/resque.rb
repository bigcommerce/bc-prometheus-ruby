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

          # Installed first, and independently of the flag below. It is the safety net for every observation pushed
          # from a forked child, so it must not depend on the collectors that follow starting successfully.
          install_fork_reset(resque_client)

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
        # Resque runs after_fork in the child, after reconnect and before the job body, which is the only point where
        # the inherited copy can be dropped before anything tries to use it. Registered whatever the per-job metrics
        # setting is: Collectors::Resque pushes from the parent every 30 seconds, so a child can inherit queued
        # messages either way.
        #
        # Idempotent, because Resque appends after_fork hooks rather than replacing them.
        #
        # @param [PrometheusExporter::Client] client
        #
        def self.install_fork_reset(client)
          return if @fork_reset_installed

          ::Resque.after_fork { |_job| client.reset_after_fork! if client.respond_to?(:reset_after_fork!) }
          @fork_reset_installed = true
        end
        private_class_method :install_fork_reset
      end
    end
  end
end
