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
require 'json'
require 'socket'

##
# Stands in for the exporter server and counts what arrives at /send-metrics.
#
# The fork-integration specs assert on how many observations actually crossed the process boundary, so they need a real
# listener rather than a stubbed client. Counting envelopes here keeps those assertions independent of type collector
# registration and of the exposition format.
#
class CountingExporter
  # @return [Integer] the ephemeral port the exporter bound to
  attr_reader :port

  def initialize
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @envelopes = []
    @mutex = Mutex.new
  end

  def start
    @thread = Thread.new do
      loop do
        connection = @server.accept
        Thread.new(connection) { |socket| serve(socket) }
      end
    end
    self
  end

  def stop
    @thread&.kill
    begin
      @server.close
    rescue StandardError
      nil
    end
  end

  ##
  # @param [String] name only count envelopes for this metric, ignoring anything the collectors also push
  # @return [Integer]
  #
  def count_for(name)
    @mutex.synchronize { @envelopes.count { |envelope| envelope['name'] == name } }
  end

  private

  def serve(socket)
    request_line = socket.gets
    body = read_body(socket)
    record(body) if request_line.to_s.include?('/send-metrics')
    socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
  rescue StandardError
    nil
  ensure
    begin
      socket.close
    rescue StandardError
      nil
    end
  end

  def read_body(socket)
    content_length = 0
    while (line = socket.gets) && line != "\r\n"
      content_length = line.split(':', 2).last.to_i if line.downcase.start_with?('content-length:')
    end
    content_length.positive? ? socket.read(content_length).to_s : ''
  end

  def record(body)
    envelope = JSON.parse(body)
    @mutex.synchronize { @envelopes << envelope }
  rescue JSON::ParserError
    nil
  end
end
