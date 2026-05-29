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

# Classification only: which payload class .for builds for each wire shape.
# The field extraction behaviour of each class is covered in
# active_job_payload_spec.rb and vanilla_resque_payload_spec.rb.

describe Bigcommerce::Prometheus::Integrations::Resque::JobPayload do
  def resque_job_double(payload)
    double('Resque::Job', payload: payload)
  end

  def active_job_payload(job_class: 'MyJob', enqueued_at: nil, scheduled_at: nil)
    {
      'class' => 'ActiveJob::QueueAdapters::ResqueAdapter::JobWrapper',
      'args' => [
        {
          'job_class' => job_class,
          'arguments' => [],
          'enqueued_at' => enqueued_at,
          'scheduled_at' => scheduled_at
        }.compact
      ]
    }
  end

  describe '.for' do
    it 'builds an ActiveJobPayload for an ActiveJob-shaped payload' do
      payload = described_class.for(resque_job_double(active_job_payload))

      expect(payload).to be_a(Bigcommerce::Prometheus::Integrations::Resque::ActiveJobPayload)
    end

    it 'labels by the inner job_class, never the JobWrapper class' do
      payload = described_class.for(resque_job_double(active_job_payload(job_class: 'BigPay::InnerJob')))

      expect(payload.job_class).to eq('BigPay::InnerJob')
    end

    it 'builds a VanillaResquePayload for a vanilla payload (primitive args)' do
      payload = described_class.for(
        resque_job_double('class' => 'BigPay::EnablePpcpJob', 'args' => [12_345, 'some_string'])
      )

      expect(payload).to be_a(Bigcommerce::Prometheus::Integrations::Resque::VanillaResquePayload)
    end

    it 'builds a VanillaResquePayload when args is empty' do
      payload = described_class.for(resque_job_double('class' => 'BigPay::EmptyJob', 'args' => []))

      expect(payload).to be_a(Bigcommerce::Prometheus::Integrations::Resque::VanillaResquePayload)
    end

    it 'builds a VanillaResquePayload when args is missing' do
      payload = described_class.for(resque_job_double('class' => 'BigPay::EmptyJob'))

      expect(payload).to be_a(Bigcommerce::Prometheus::Integrations::Resque::VanillaResquePayload)
    end

    it 'builds a VanillaResquePayload when args is not an Array' do
      payload = described_class.for(resque_job_double('class' => 'BigPay::WeirdJob', 'args' => 'not an array'))

      expect(payload).to be_a(Bigcommerce::Prometheus::Integrations::Resque::VanillaResquePayload)
    end

    it 'builds a VanillaResquePayload when args[0] is a Hash without a job_class' do
      payload = described_class.for(
        resque_job_double('class' => 'BigPay::HashArgJob', 'args' => [{ 'enqueued_at' => Time.now.iso8601 }])
      )

      expect(payload).to be_a(Bigcommerce::Prometheus::Integrations::Resque::VanillaResquePayload)
    end

    it 'builds a VanillaResquePayload when the inner job_class is nil (no nil labels)' do
      payload = described_class.for(
        resque_job_double('class' => 'BigPay::HashArgJob', 'args' => [{ 'job_class' => nil }])
      )

      expect(payload).to be_a(Bigcommerce::Prometheus::Integrations::Resque::VanillaResquePayload)
    end

    it "builds a VanillaResquePayload when the job's payload is nil" do
      payload = described_class.for(resque_job_double(nil))

      expect(payload).to be_a(Bigcommerce::Prometheus::Integrations::Resque::VanillaResquePayload)
    end

    it 'builds a VanillaResquePayload when the payload is not a Hash' do
      payload = described_class.for(resque_job_double('not a hash'))

      expect(payload).to be_a(Bigcommerce::Prometheus::Integrations::Resque::VanillaResquePayload)
    end

    it "normalizes a non-Hash payload so the label falls back to 'unknown'" do
      expect(described_class.for(resque_job_double(nil)).job_class).to eq('unknown')
    end

    it "returns a VanillaResquePayload labelled 'unknown' when payload access raises" do
      job = double('Resque::Job')
      allow(job).to receive(:payload).and_raise(StandardError, 'boom')

      payload = described_class.for(job)

      expect(payload).to be_a(Bigcommerce::Prometheus::Integrations::Resque::VanillaResquePayload)
      expect(payload.job_class).to eq('unknown')
    end
  end
end
