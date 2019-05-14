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
      # Railtie for automatic configuration of Rails environments
      #
      class Railtie < ::Rails::Railtie
        initializer 'zzz_bigcommerce.prometheus.configure_rails_initialization' do |app|
          if Bigcommerce::Prometheus.enabled
            Bigcommerce::Prometheus.logger.debug '[bigcommerce-prometheus] Loading railtie'

            app.config.before_fork_callbacks = [] unless Rails.application.config.before_fork_callbacks
            app.config.before_fork_callbacks << lambda do
              ::Bigcommerce::Prometheus::Server.new(
                port: Bigcommerce::Prometheus.server_port,
                timeout: Bigcommerce::Prometheus.server_timeout,
                prefix: Bigcommerce::Prometheus.server_prefix
              ).start
            end

            app.config.after_fork_callbacks = [] unless Rails.application.config.after_fork_callbacks
            app.config.after_fork_callbacks << lambda do
              ::Bigcommerce::Prometheus::Integrations::Puma.start
            end

            app.middleware.unshift(PrometheusExporter::Middleware, client: Bigcommerce::Prometheus.client)
          else
            Rails.logger.info '[bigcommerce-prometheus] Prometheus disabled, skipping...'
          end
        end
      end
    end
  end
end
