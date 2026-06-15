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
require 'spec_helper'

describe Bigcommerce::Prometheus::Server do
  let(:thread) { instance_double(Thread, join: nil, kill: nil) }
  let(:puma_server) do
    instance_double(
      Bigcommerce::Prometheus::Servers::Puma::Server,
      stop: nil,
      run: thread,
      max_threads: 1,
      add_type_collector: nil
    )
  end
  let(:server) do
    allow(Bigcommerce::Prometheus::Servers::Puma::Server).to receive(:new).and_return(puma_server)
    described_class.new
  end

  describe '#stop' do
    context 'when start was never called (@run_thread is nil)' do
      it 'does not raise' do
        expect { server.stop }.not_to raise_error
      end

      it 'sets running? to false' do
        server.stop
        expect(server.running?).to be false
      end
    end

    context 'when start was called successfully' do
      before { server.start }

      it 'kills the run thread' do
        expect(thread).to receive(:kill)
        server.stop
      end

      it 'sets running? to false' do
        server.stop
        expect(server.running?).to be false
      end
    end
  end

  describe '#running?' do
    it 'is false before start is called' do
      expect(server.running?).to be false
    end
  end
end
