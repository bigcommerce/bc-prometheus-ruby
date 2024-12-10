require 'spec_helper'

describe Bigcommerce::Prometheus::Servers::Puma::Server do
  let(:server) { described_class.new(port: default_port) }
  let(:default_port) { 9800 + rand(100) }
  before do
    Bigcommerce::Prometheus.reset
  end

  context 'when the server is initialized' do
    it 'has a valid rack app' do
      expect(server.app).to be_a(Bigcommerce::Prometheus::Servers::Puma::RackApp)
    end
  end

  context 'when the thread pool size is not configured' do
    it 'falls back to the default configuration' do
      expect(server.max_threads).to eq ::Bigcommerce::Prometheus.server_thread_pool_size
      expect(server.max_threads).to eq 3
    end
  end

  context 'when the default thread pool size is configured' do
    let(:server_thread_pool_size) { 12 }

    before do
      Bigcommerce::Prometheus.configure do |c|
        c.server_thread_pool_size = server_thread_pool_size
      end
    end

    it 'allows you to set the thread pool size through the configuration block' do
      expect(server.max_threads).to eq server_thread_pool_size
    end
  end

  context 'when the default port is configured' do
    let(:server_port) { 9000 + rand(100) }
    let(:default_port) { nil }

    before do
      Bigcommerce::Prometheus.configure do |c|
        c.server_port = server_port
      end
    end

    it 'allows you to set the port through the configuration block' do
      expect(server.connected_ports).to include server_port
    end
  end
end
