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
    ##
    # Sends the queued metrics to the collector.
    #
    class Delivery
      include Loggable

      ##
      # @param [Queue] queue the data structure metrics are pushed onto.
      # @param [String] host the collector host.
      # @param [Integer] port the collector port.
      # @param [String] process_name
      #
      def initialize(queue:, host:, port:, process_name:)
        @queue = queue
        @host = host
        @port = port
        @process_name = process_name
      end

      def process_queue
        drain
      end

      ##
      # @param [String] path appended to the collector's base URL.
      # @return [Module<URI>]
      #
      def uri_path(path)
        URI("http://#{@host}:#{@port}#{path}")
      end

      private

      def drain
        while @queue.length.to_i.positive?
          begin
            post_message(@queue.pop)
          rescue StandardError => e
            report("Prometheus Exporter is dropping a message to #{uri_path('/send-metrics')}: #{e}")
            raise
          end
        end
      end

      ##
      # @param [String] message the serialized metric to deliver.
      #
      def post_message(message)
        ::Net::HTTP.post(uri_path('/send-metrics'), message)
      end

      ##
      # @param [String] message the warning to write.
      #
      def report(message)
        logger.warn "[bigcommerce-prometheus][#{@process_name}] #{message}"
        $stdout.flush
        $stderr.flush
      rescue StandardError
        nil
      end
    end
  end
end
