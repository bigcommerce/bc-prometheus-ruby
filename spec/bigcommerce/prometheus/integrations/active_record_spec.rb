# frozen_string_literal: true

require 'spec_helper'
require 'active_support/notifications'

describe Bigcommerce::Prometheus::Integrations::ActiveRecordSql do
  let(:client) { instance_double(Bigcommerce::Prometheus::Client, send_json: nil) }

  def event_for(sql:, name: nil, duration_ms: 12.5)
    started = Time.now
    finished = started + (duration_ms / 1000.0)
    ActiveSupport::Notifications::Event.new('sql.active_record', started, finished, 'id', { sql: sql, name: name })
  end

  describe '.start' do
    before { described_class.instance_variable_set(:@start, nil) }
    after { described_class.instance_variable_set(:@start, nil) }

    it 'registers a listener on sql.active_record' do
      expect(ActiveSupport::Notifications).to receive(:subscribe).with('sql.active_record')
      described_class.start(client: client)
    end

    it 'is idempotent — calling .start twice only registers one subscriber' do
      allow(ActiveSupport::Notifications).to receive(:subscribe).with('sql.active_record')
      described_class.start(client: client)
      described_class.start(client: client)
      expect(ActiveSupport::Notifications).to have_received(:subscribe).with('sql.active_record').once
    end
  end

  describe '#call' do
    let(:integration) { described_class.new(client: client) }

    it 'pushes SELECT events as operation "select" with duration in seconds' do
      event = event_for(sql: 'SELECT * FROM users WHERE id = 1', duration_ms: 25)

      expect(client).to receive(:send_json).with(
        hash_including(
          type: 'active_record_sql',
          duration_seconds: a_value_within(0.001).of(0.025),
          custom_labels: { operation: 'select' }
        )
      )

      integration.call(event)
    end

    it 'pushes INSERT events as operation "insert"' do
      event = event_for(sql: 'INSERT INTO users (name) VALUES (?)')
      expect(client).to receive(:send_json).with(hash_including(custom_labels: { operation: 'insert' }))
      integration.call(event)
    end

    it 'pushes UPDATE events as operation "update"' do
      event = event_for(sql: 'UPDATE users SET name = ? WHERE id = ?')
      expect(client).to receive(:send_json).with(hash_including(custom_labels: { operation: 'update' }))
      integration.call(event)
    end

    it 'pushes DELETE events as operation "delete"' do
      event = event_for(sql: 'DELETE FROM users WHERE id = ?')
      expect(client).to receive(:send_json).with(hash_including(custom_labels: { operation: 'delete' }))
      integration.call(event)
    end

    it 'pushes unrecognized statements as operation "other"' do
      event = event_for(sql: 'BEGIN TRANSACTION')
      expect(client).to receive(:send_json).with(hash_including(custom_labels: { operation: 'other' }))
      integration.call(event)
    end

    it 'ignores SCHEMA events' do
      event = event_for(sql: 'SHOW FULL FIELDS FROM users', name: 'SCHEMA')
      expect(client).not_to receive(:send_json)
      integration.call(event)
    end

    it 'ignores CACHE events' do
      event = event_for(sql: 'SELECT * FROM users', name: 'CACHE')
      expect(client).not_to receive(:send_json)
      integration.call(event)
    end

    it 'classifies case-insensitively' do
      event = event_for(sql: 'select * from users')
      expect(client).to receive(:send_json).with(hash_including(custom_labels: { operation: 'select' }))
      integration.call(event)
    end

    it 'tolerates leading whitespace and newlines' do
      event = event_for(sql: "  \n  SELECT 1")
      expect(client).to receive(:send_json).with(hash_including(custom_labels: { operation: 'select' }))
      integration.call(event)
    end

    it 'classifies nil SQL as "other" without raising' do
      event = event_for(sql: nil)
      expect(client).to receive(:send_json).with(hash_including(custom_labels: { operation: 'other' }))
      expect { integration.call(event) }.not_to raise_error
    end

    it 'never raises if the client raises' do
      event = event_for(sql: 'SELECT 1')
      allow(client).to receive(:send_json).and_raise(StandardError, 'boom')
      expect { integration.call(event) }.not_to raise_error
    end
  end

  describe '.register_type_collector' do
    let(:server) { instance_double(Bigcommerce::Prometheus::Server, add_type_collector: nil) }

    it 'registers the AR type collector when the feature is enabled' do
      allow(Bigcommerce::Prometheus).to receive(:active_record_enabled).and_return(true)
      expect(server).to receive(:add_type_collector).with(instance_of(Bigcommerce::Prometheus::TypeCollectors::ActiveRecordSql))
      described_class.register_type_collector(server)
    end

    it 'does nothing when the feature is disabled' do
      allow(Bigcommerce::Prometheus).to receive(:active_record_enabled).and_return(false)
      expect(server).not_to receive(:add_type_collector)
      described_class.register_type_collector(server)
    end

    it 'never raises if registration fails' do
      allow(Bigcommerce::Prometheus).to receive(:active_record_enabled).and_return(true)
      allow(server).to receive(:add_type_collector).and_raise(StandardError, 'boom')
      expect { described_class.register_type_collector(server) }.not_to raise_error
    end
  end

  describe '.start_safe' do
    it 'starts the integration when the feature is enabled' do
      allow(Bigcommerce::Prometheus).to receive(:active_record_enabled).and_return(true)
      expect(described_class).to receive(:start).with(client: client)
      described_class.start_safe(client: client)
    end

    it 'does nothing when the feature is disabled' do
      allow(Bigcommerce::Prometheus).to receive(:active_record_enabled).and_return(false)
      expect(described_class).not_to receive(:start)
      described_class.start_safe(client: client)
    end

    it 'never raises if start fails' do
      allow(Bigcommerce::Prometheus).to receive(:active_record_enabled).and_return(true)
      allow(described_class).to receive(:start).and_raise(StandardError, 'boom')
      expect { described_class.start_safe(client: client) }.not_to raise_error
    end
  end
end
