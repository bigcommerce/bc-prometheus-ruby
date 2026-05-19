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
      # Subscribes to ActiveSupport sql.active_record notifications and pushes a per-operation
      # SQL query duration histogram to the Prometheus exporter.
      #
      class ActiveRecordSql
        IGNORED_NAMES = %w[SCHEMA CACHE].freeze
        TYPE = 'active_record_sql'

        # Idempotent: returns the same instance on repeated calls within a process,
        # so calling .start more than once (e.g. from both the gem's instrumentor and a
        # consuming app's initializer) does not register duplicate subscribers and
        # double-count every SQL query.
        #
        # Noop when ActiveRecord is not loaded so non-Rails consumers (or any process that
        # never loads ActiveRecord) can call this safely.
        def self.start(client: nil)
          return unless active_record_loaded?

          @start ||= new(client: client || ::Bigcommerce::Prometheus.client).tap(&:subscribe!)
        end

        # @return [Boolean] whether ActiveRecord is loaded in the current process.
        def self.active_record_loaded?
          defined?(::ActiveRecord) ? true : false
        end

        # Wrapper for instrumentor wiring: registers the AR SQL type collector on the given server,
        # gated on the active_record_enabled config flag, and swallows errors so an additive
        # feature failure cannot take down core instrumentation.
        def self.register_type_collector(server, process_name: nil)
          return unless ::Bigcommerce::Prometheus.active_record_enabled

          server.add_type_collector(::Bigcommerce::Prometheus::TypeCollectors::ActiveRecordSql.new)
        rescue StandardError => e
          log_warn(process_name, "Failed to register ActiveRecord type collector: #{e.message}")
        end

        # Wrapper for instrumentor wiring: starts the AR integration, gated on the
        # active_record_enabled config flag, and swallows errors so an additive feature
        # failure cannot take down core instrumentation.
        def self.start_safe(client: nil, process_name: nil)
          return unless ::Bigcommerce::Prometheus.active_record_enabled

          start(client: client)
        rescue StandardError => e
          log_warn(process_name, "Failed to start ActiveRecord integration: #{e.message}")
        end

        def self.log_warn(process_name, message)
          process_name ||= ::Bigcommerce::Prometheus.process_name
          ::Bigcommerce::Prometheus.logger&.warn("[bigcommerce-prometheus][#{process_name}] #{message}")
        end
        private_class_method :log_warn

        def initialize(client:)
          @client = client
        end

        def subscribe!
          ActiveSupport::Notifications.subscribe('sql.active_record') do |*args|
            call(ActiveSupport::Notifications::Event.new(*args))
          end
        end

        def call(event)
          return if IGNORED_NAMES.include?(event.payload[:name])

          @client.send_json(
            type: TYPE,
            duration_seconds: event.duration / 1000.0,
            custom_labels: { operation: classify(event.payload[:sql]) }
          )
        rescue StandardError
          # Never let metric instrumentation propagate into the request path.
          nil
        end

        private

        def classify(sql)
          return 'other' if sql.nil?

          first_token = sql.lstrip.split(/\s+/, 2).first&.upcase
          case first_token
          when 'SELECT' then 'select'
          when 'INSERT' then 'insert'
          when 'UPDATE' then 'update'
          when 'DELETE' then 'delete'
          else 'other'
          end
        end
      end
    end
  end
end
