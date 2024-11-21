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
require 'bigcommerce/multitrap'
require 'net/http'
require 'prometheus_exporter'
require 'prometheus_exporter/server'
require 'prometheus_exporter/client'
require 'prometheus_exporter/middleware'
require 'prometheus_exporter/instrumentation'
require 'puma'
require 'rack'

require_relative 'prometheus/version'
require_relative 'prometheus/loggable'
require_relative 'prometheus/configuration'
require_relative 'prometheus/server'
require_relative 'prometheus/client'

require_relative 'prometheus/collectors/base'
require_relative 'prometheus/collectors/resque'
require_relative 'prometheus/type_collectors/base'
require_relative 'prometheus/type_collectors/resque'

require_relative 'prometheus/instrumentors/web'
require_relative 'prometheus/instrumentors/hutch'
require_relative 'prometheus/instrumentors/resque'
require_relative 'prometheus/integrations/railtie' if defined?(Rails)
require_relative 'prometheus/integrations/puma'
require_relative 'prometheus/integrations/resque'

require_relative 'prometheus/servers/puma/server'
require_relative 'prometheus/servers/puma/rack_app'
require_relative 'prometheus/servers/puma/server_metrics'
require_relative 'prometheus/servers/puma/controllers/base_controller'
require_relative 'prometheus/servers/puma/controllers/error_controller'
require_relative 'prometheus/servers/puma/controllers/metrics_controller'
require_relative 'prometheus/servers/puma/controllers/not_found_controller'
require_relative 'prometheus/servers/puma/controllers/send_metrics_controller'

module Bigcommerce
  ##
  # Base top-level prometheus module
  #
  module Prometheus
    extend Configuration

    ##
    # @return [Bigcommerce::Prometheus::Client]
    #
    def self.client
      Client.instance
    end
  end
end
