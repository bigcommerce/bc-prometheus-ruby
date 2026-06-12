# frozen_string_literal: true

require 'spec_helper'

describe Bigcommerce::Prometheus do
  describe 'configuration' do
    describe 'resque_process_label' do
      subject { described_class.resque_process_label }

      it 'defaults to resque' do
        expect(subject).to eq('resque')
      end
    end
  end
end
