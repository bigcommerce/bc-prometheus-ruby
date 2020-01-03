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
      # Plugin for puma
      #
      class Puma
        ##
        # Start the puma collector
        #
        def self.start(client: nil, frequency: nil)
          return unless puma_enabled?

          if puma_enabled?
            ::PrometheusExporter::Instrumentation::Puma.start(
              client: client || ::Bigcommerce::Prometheus.client,
              frequency: frequency || ::Bigcommerce::Prometheus.puma_collection_frequency
            )
          end
          if active_record_enabled?
            ::PrometheusExporter::Instrumentation::ActiveRecord.start(
              client: client || ::Bigcommerce::Prometheus.client,
              frequency: frequency || ::Bigcommerce::Prometheus.puma_collection_frequency
            )
          end
          ::PrometheusExporter::Instrumentation::Process.start(
            client: client || ::Bigcommerce::Prometheus.client,
            type: ::Bigcommerce::Prometheus.puma_process_label,
            frequency: frequency || ::Bigcommerce::Prometheus.puma_collection_frequency
          )
        end

        ##
        # @return [Boolean]
        #
        def self.active_record_enabled?
          defined?(ActiveRecord) && ::ActiveRecord::Base.connection_pool.respond_to?(:stat)
        end

        ##
        # @return [Boolean]
        #
        def self.puma_enabled?
          defined?(::Puma) && ::Puma.respond_to?(:stats)
        end
      end
    end
  end
end
