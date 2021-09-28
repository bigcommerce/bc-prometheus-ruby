describe Bigcommerce::Prometheus::Instrumentors::Web do
  def run!
    described_class.new(app: application).start
  end

  let(:application) do
    instance_double(Rails::Application).tap do |instance|
      allow(instance).to receive(:config).and_return(configuration)
      allow(instance).to receive(:middleware).and_return(middleware)
    end
  end

  let(:configuration) { Rails::Engine::Configuration.new }
  let(:middleware) { [] }

  it 'properly handles lack of the fork configs' do
    expect(Bigcommerce::Prometheus.logger).not_to receive(:error)

    run!

    expect(configuration.respond_to?(:before_fork_callbacks)).to eq(true)
    expect(configuration.respond_to?(:after_fork_callbacks)).to eq(true)
    expect(configuration.before_fork_callbacks).to be_an_instance_of(Array)
    expect(configuration.after_fork_callbacks).to be_an_instance_of(Array)
  end

  context 'when configuration already set' do
    before do
      configuration.before_fork_callbacks = [1]
      configuration.after_fork_callbacks = [1]
    end

    it 'just adds another elements' do
      run!

      expect(configuration.before_fork_callbacks.size).to eq(2)
      expect(configuration.after_fork_callbacks.size).to eq(2)
    end
  end
end
