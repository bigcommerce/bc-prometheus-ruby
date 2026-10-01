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
    # Sends the metrics to the collector
    #
    class Delivery
      ##
      # Error sending to collector
      #
      class PostFailed < StandardError
        attr_reader :cause, :sent, :undelivered, :uri_path

        def initialize(cause:, sent:, undelivered:, uri_path:)
          @cause = cause
          @sent = sent
          @undelivered = undelivered
          @uri_path = uri_path
          super(build_message)
        end

        private

        def build_message
          base = "dropping a message to #{uri_path}: #{cause}"
          undelivered.positive? ? "#{base} (#{undelivered} more left undelivered)" : base
        end
      end

      def initialize(queue:, host:, port:)
        @queue = queue
        @host = host
        @port = port
        @delivery_mutex = Mutex.new
      end

      def process_queue
        @delivery_mutex.synchronize { drain }
      end

      def queue_size
        @queue.size
      end

      def uri_path(path)
        URI("http://#{@host}:#{@port}#{path}")
      end

      private

      def drain
        sent = 0
        while @queue.length.to_i.positive?
          begin
            post_message(@queue.pop)
            sent += 1
          rescue StandardError => e
            raise PostFailed.new(cause: e, sent: sent, undelivered: @queue.size, uri_path: uri_path('/send-metrics'))
          end
        end
        sent.zero? ? :empty : :success
      end

      def post_message(message)
        ::Net::HTTP.post(uri_path('/send-metrics'), message)
      end
    end
  end
end
