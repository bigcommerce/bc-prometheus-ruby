# frozen_string_literal: true

require 'spec_helper'

describe Bigcommerce::Prometheus do
  describe 'configuration' do
    describe 'resque_process_label' do
      subject { described_class.resque_process_label }

      context 'when PROMETHEUS_RESQUE_PROCESS_LABEL is set' do
        before do
          described_class.resque_process_label = 'worker'
        end

        after do
          described_class.resque_process_label = 'resque'
        end

        it 'uses the env var value' do
          expect(subject).to eq('worker')
        end
      end

      context 'when no env var is set' do
        it 'defaults to resque' do
          expect(subject).to eq('resque')
        end
      end
    end
  end
end
