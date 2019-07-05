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
require 'timeout'
require 'zlib'
require 'stringio'

module Bigcommerce
  module Prometheus
    module Servers
      module Thin
        module Controllers
          ##
          # GET /metrics
          #
          class MetricsController < BaseController
            ##
            # Handle outputting of metrics
            #
            def call
              collected_metrics = metrics
              if @request.accept_encoding.to_s.include?('gzip')
                write_gzip(metrics)
              else
                @response.write(collected_metrics)
              end
              @response
            end

            private

            ##
            # Output via gzip
            #
            def write_gzip(metrics)
              sio = ::StringIO.new
              begin
                writer = ::Zlib::GzipWriter.new(sio)
                writer.write(metrics)
              ensure
                writer.close
              end
              @response.body << sio.string
              set_header('Content-Encoding', 'gzip')
            end

            ##
            # Gather all metrics
            #
            def metrics
              metric_text = ''
              working = true

              begin
                ::Timeout.timeout(@timeout) do
                  metric_text = @collector.prometheus_metrics_text
                end
              rescue ::Timeout::Error
                working = false
                @logger.error 'Generating Prometheus metrics text timed out'
              end

              output = []
              output << @server_metrics.to_prometheus_text(working: working)
              output << metric_text
              output.join("\n")
            end
          end
        end
      end
    end
  end
end
