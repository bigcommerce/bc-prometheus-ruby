# ENGP-429 Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix 6 confirmed bugs found in the bc-prometheus-ruby gem code review, each on its own stacked GitButler branch so they land as separate reviewable PRs.

**Architecture:** Six independent fixes touching different files. Stacked linearly with `but branch new <name> --anchor <prev>` so each PR is reviewable in isolation and merges cleanly in order. All fixes follow TDD: failing test first, minimal implementation second.

**Tech Stack:** Ruby, RSpec, GitButler CLI (`but`)

---

## GitButler Stacking Setup

Before Task 1, confirm the workspace is clean:

```bash
but status
# Should show: no uncommitted changes
```

The six branches stack in this order:
```
main
  └─ ENGP-429-fix-env-var
       └─ ENGP-429-fix-run-thread
            └─ ENGP-429-fix-collector-thread
                 └─ ENGP-429-fix-queues-nil
                      └─ ENGP-429-fix-gzip-double-metrics
                           └─ ENGP-429-fix-timeout-passthrough
```

Each `but commit <branch>` call targets the correct branch by name. Since each fix touches a different file, GitButler can always unambiguously assign hunks.

---

## Task 1: Fix wrong env var for `resque_process_label`

**Files:**
- Modify: `lib/bigcommerce/prometheus/configuration.rb:37`
- Test: `spec/bigcommerce/prometheus/configuration_spec.rb` (create new)

**Bug:** `resque_process_label` reads `PROMETHEUS_REQUEST_PROCESS_LABEL` (typo: `REQUEST` instead of `RESQUE`). Setting the correct env var is silently ignored.

- [ ] **Step 1: Create the GitButler branch**

```bash
but branch new ENGP-429-fix-env-var
```

- [ ] **Step 2: Write the failing test**

Create `spec/bigcommerce/prometheus/configuration_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

describe Bigcommerce::Prometheus do
  describe 'configuration' do
    describe 'resque_process_label' do
      subject { described_class.resque_process_label }

      context 'when PROMETHEUS_RESQUE_PROCESS_LABEL is set' do
        before do
          ENV['PROMETHEUS_RESQUE_PROCESS_LABEL'] = 'worker'
          described_class.reset
        end

        after do
          ENV.delete('PROMETHEUS_RESQUE_PROCESS_LABEL')
          described_class.reset
        end

        it 'uses the env var value' do
          expect(subject).to eq('worker')
        end
      end

      context 'when no env var is set' do
        before { described_class.reset }

        it 'defaults to resque' do
          expect(subject).to eq('resque')
        end
      end
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

```bash
bundle exec rspec spec/bigcommerce/prometheus/configuration_spec.rb -f doc
```

Expected: FAIL — `expected: "worker" got: "resque"` (env var not read)

- [ ] **Step 4: Apply the fix**

In `lib/bigcommerce/prometheus/configuration.rb`, line 37, change:

```ruby
resque_process_label: ENV.fetch('PROMETHEUS_REQUEST_PROCESS_LABEL', 'resque').to_s,
```

to:

```ruby
resque_process_label: ENV.fetch('PROMETHEUS_RESQUE_PROCESS_LABEL', 'resque').to_s,
```

- [ ] **Step 5: Run test to verify it passes**

```bash
bundle exec rspec spec/bigcommerce/prometheus/configuration_spec.rb -f doc
```

Expected: 2 examples, 0 failures

- [ ] **Step 6: Run full suite to confirm no regressions**

```bash
bundle exec rspec
```

Expected: all examples pass

- [ ] **Step 7: Commit to the branch**

```bash
but commit ENGP-429-fix-env-var -m "fix(config): correct env var name for resque_process_label

PROMETHEUS_REQUEST_PROCESS_LABEL was a typo; correct name is
PROMETHEUS_RESQUE_PROCESS_LABEL, matching the pattern used by
PROMETHEUS_PUMA_PROCESS_LABEL.

Refs: ENGP-429"
```

---

## Task 2: Fix `@run_thread.kill` nil-dereference in `Server#stop`

**Files:**
- Modify: `lib/bigcommerce/prometheus/server.rb:83`
- Test: add context to `spec/bigcommerce/prometheus/servers/puma/server_spec.rb` (no such spec exists yet — create it at the Server level)

There is no Server-level spec. We will add one.

**Files:**
- Create: `spec/bigcommerce/prometheus/server_spec.rb`

**Bug:** `Server#stop` calls `@run_thread.kill` unconditionally. `@run_thread` is nil if `start` was never called or raised before the assignment. Signal handlers (INT/TERM) registered in `initialize` can trigger `stop` at any time. The `NoMethodError` is caught by `stop`'s rescue, meaning `@running` is never reset to `false`.

- [ ] **Step 1: Create the stacked GitButler branch**

```bash
but branch new ENGP-429-fix-run-thread --anchor ENGP-429-fix-env-var
```

- [ ] **Step 2: Write the failing test**

Create `spec/bigcommerce/prometheus/server_spec.rb`:

```ruby
# frozen_string_literal: true

require 'spec_helper'

describe Bigcommerce::Prometheus::Server do
  let(:puma_server) { instance_double(Bigcommerce::Prometheus::Servers::Puma::Server, stop: nil, run: thread, max_threads: 1, add_type_collector: nil) }
  let(:thread) { instance_double(Thread, join: nil, kill: nil) }
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
    it 'is false before start' do
      expect(server.running?).to be false
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

```bash
bundle exec rspec spec/bigcommerce/prometheus/server_spec.rb -f doc
```

Expected: FAIL — `NoMethodError: undefined method 'kill' for nil` or `@running` stuck at false when thread kill raises

- [ ] **Step 4: Apply the fix**

In `lib/bigcommerce/prometheus/server.rb`, change `stop` so that:
1. `@run_thread&.kill` (safe navigation — no-ops if nil)
2. `@running = false` moves to `ensure` so it always executes even if an error occurs

```ruby
def stop
  @server.stop
  @run_thread&.kill
  $stdout.puts "[bigcommerce-prometheus][#{@process_name}] Prometheus exporter cleanly shut down"
rescue ::StandardError => e
  warn "[bigcommerce-prometheus][#{@process_name}] Failed to stop exporter: #{e.message}"
ensure
  @running = false
end
```

- [ ] **Step 5: Run test to verify it passes**

```bash
bundle exec rspec spec/bigcommerce/prometheus/server_spec.rb -f doc
```

Expected: all examples pass

- [ ] **Step 6: Run full suite**

```bash
bundle exec rspec
```

Expected: all examples pass

- [ ] **Step 7: Commit**

```bash
but commit ENGP-429-fix-run-thread -m "fix(server): guard against nil @run_thread in Server#stop

@run_thread is nil if stop is called before start (e.g. via signal
handlers registered in initialize). Use safe navigation &.kill and
move @running = false to ensure so it always executes.

Refs: ENGP-429"
```

---

## Task 3: Fix collector thread dying silently on `collect` errors

**Files:**
- Modify: `lib/bigcommerce/prometheus/collectors/base.rb:36-40`
- Modify: `spec/bigcommerce/prometheus/collectors/base_spec.rb`

**Bug:** `Kernel.loop` only rescues `StopIteration`. Any `StandardError` from `collect` propagates out of the loop and terminates the thread permanently with no log and no restart.

- [ ] **Step 1: Create the stacked GitButler branch**

```bash
but branch new ENGP-429-fix-collector-thread --anchor ENGP-429-fix-run-thread
```

- [ ] **Step 2: Write the failing test**

Add to `spec/bigcommerce/prometheus/collectors/base_spec.rb` inside the `describe Bigcommerce::Prometheus::Collectors::Base` block:

```ruby
describe '.start — thread resilience' do
  let(:error_collector_class) do
    Class.new(Bigcommerce::Prometheus::Collectors::Base) do
      def collect(metrics)
        raise StandardError, 'Redis gone'
      end
    end
  end

  it 'keeps the thread alive after collect raises' do
    thread = error_collector_class.start(client: double(:client, send_json: true), frequency: 0)
    sleep 0.05  # let the thread run at least a few iterations
    expect(thread).to be_alive
  ensure
    error_collector_class.stop
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

```bash
bundle exec rspec spec/bigcommerce/prometheus/collectors/base_spec.rb -f doc
```

Expected: FAIL — thread is dead (`be_alive` fails)

- [ ] **Step 4: Apply the fix**

In `lib/bigcommerce/prometheus/collectors/base.rb`, add a rescue to `run` so errors from `collect` are caught there (where `@logger` is directly accessible) and the loop continues:

```ruby
def run
  metrics = {}
  metrics = collect(metrics)
  push(metrics)
rescue StandardError => e
  @logger.error("[bigcommerce-prometheus] Collector error (#{self.class}), continuing: #{e.message}")
ensure
  sleep @frequency
end
```

- [ ] **Step 5: Run test to verify it passes**

```bash
bundle exec rspec spec/bigcommerce/prometheus/collectors/base_spec.rb -f doc
```

Expected: all examples pass

- [ ] **Step 6: Run full suite**

```bash
bundle exec rspec
```

Expected: all examples pass

- [ ] **Step 7: Commit**

```bash
but commit ENGP-429-fix-collector-thread -m "fix(collectors): rescue StandardError in collector loop to prevent silent thread death

Kernel.loop only rescues StopIteration. Any error from collect (e.g.
Redis unavailable) killed the thread permanently with no log and no
restart. Now errors are logged and the loop continues.

Refs: ENGP-429"
```

---

## Task 4: Fix `data['queues'].each` nil-crash in Resque type collector

**Files:**
- Modify: `lib/bigcommerce/prometheus/type_collectors/resque.rb:51`
- Modify: `spec/bigcommerce/prometheus/type_collectors/resque_spec.rb`

**Bug:** `data['queues'].each` raises `NoMethodError` if the `'queues'` key is absent or nil — for example, when a mismatched client binary omits the key.

- [ ] **Step 1: Create the stacked GitButler branch**

```bash
but branch new ENGP-429-fix-queues-nil --anchor ENGP-429-fix-collector-thread
```

- [ ] **Step 2: Write the failing test**

Add a new context inside the `describe '#collect_metrics'` block in `spec/bigcommerce/prometheus/type_collectors/resque_spec.rb`:

```ruby
context 'when queues key is absent from data' do
  let(:data_without_queues) do
    {
      'workers_total' => 2,
      'jobs_failed_total' => 0,
      'jobs_pending_total' => 1,
      'jobs_processed_total' => 500,
      'queues_total' => 0
    }
  end

  it 'does not raise' do
    expect { type_collector.collect_metrics(data: data_without_queues, labels: {}) }.not_to raise_error
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

```bash
bundle exec rspec spec/bigcommerce/prometheus/type_collectors/resque_spec.rb -f doc
```

Expected: FAIL — `NoMethodError: undefined method 'each' for nil`

- [ ] **Step 4: Apply the fix**

In `lib/bigcommerce/prometheus/type_collectors/resque.rb`, change line 51:

```ruby
data['queues'].each do |name, size|
```

to:

```ruby
(data['queues'] || {}).each do |name, size|
```

- [ ] **Step 5: Run test to verify it passes**

```bash
bundle exec rspec spec/bigcommerce/prometheus/type_collectors/resque_spec.rb -f doc
```

Expected: all examples pass

- [ ] **Step 6: Run full suite**

```bash
bundle exec rspec
```

Expected: all examples pass

- [ ] **Step 7: Commit**

```bash
but commit ENGP-429-fix-queues-nil -m "fix(type_collectors): guard against nil queues in Resque#collect_metrics

data['queues'] can be nil if the sender omits the key (e.g. stale
client binary). Use (data['queues'] || {}).each to skip safely.

Refs: ENGP-429"
```

---

## Task 5: Fix `write_gzip` receiving method call instead of cached result

**Files:**
- Modify: `lib/bigcommerce/prometheus/servers/puma/controllers/metrics_controller.rb:37`
- Modify: `spec/bigcommerce/prometheus/servers/puma/controllers/metrics_controller_spec.rb`

**Bug:** `call` stores `collected_metrics = metrics` then passes `write_gzip(metrics)` — which re-invokes the `metrics` method — instead of `write_gzip(collected_metrics)`. Every gzip scrape runs `prometheus_metrics_text` twice and may return inconsistent snapshots.

- [ ] **Step 1: Create the stacked GitButler branch**

```bash
but branch new ENGP-429-fix-gzip-double-metrics --anchor ENGP-429-fix-queues-nil
```

- [ ] **Step 2: Write the failing test**

Add a context to `spec/bigcommerce/prometheus/servers/puma/controllers/metrics_controller_spec.rb` inside `describe '#call'`:

```ruby
context 'when the client accepts gzip encoding' do
  let(:env) do
    {
      'REQUEST_METHOD' => 'GET',
      'rack.input' => StringIO.new(''),
      'HTTP_ACCEPT_ENCODING' => 'gzip'
    }
  end
  let(:request) { Rack::Request.new(env) }

  it 'only calls the metrics method once' do
    call_count = 0
    allow(controller).to receive(:metrics).and_wrap_original do |m, *args|
      call_count += 1
      m.call(*args)
    end
    controller.call
    expect(call_count).to eq(1)
  end

  it 'returns gzip-encoded content' do
    result = controller.call
    encoding_header = result.headers['Content-Encoding']
    expect(encoding_header).to eq('gzip')
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

```bash
bundle exec rspec spec/bigcommerce/prometheus/servers/puma/controllers/metrics_controller_spec.rb -f doc
```

Expected: FAIL — `expected: 1, got: 2` (metrics called twice)

- [ ] **Step 4: Apply the fix**

In `lib/bigcommerce/prometheus/servers/puma/controllers/metrics_controller.rb`, change line 37:

```ruby
write_gzip(metrics)
```

to:

```ruby
write_gzip(collected_metrics)
```

- [ ] **Step 5: Run test to verify it passes**

```bash
bundle exec rspec spec/bigcommerce/prometheus/servers/puma/controllers/metrics_controller_spec.rb -f doc
```

Expected: all examples pass

- [ ] **Step 6: Run full suite**

```bash
bundle exec rspec
```

Expected: all examples pass

- [ ] **Step 7: Commit**

```bash
but commit ENGP-429-fix-gzip-double-metrics -m "fix(metrics_controller): pass collected_metrics to write_gzip, not metrics method

write_gzip(metrics) re-invoked the metrics method, causing double
collection on every gzip scrape (which is the Prometheus default).
Pass the already-computed collected_metrics instead.

Refs: ENGP-429"
```

---

## Task 6: Fix `@timeout` not passed from `RackApp` to `MetricsController`

**Files:**
- Modify: `lib/bigcommerce/prometheus/servers/puma/controllers/base_controller.rb:34-40`
- Modify: `lib/bigcommerce/prometheus/servers/puma/rack_app.rb:75-82`
- Modify: `spec/bigcommerce/prometheus/servers/puma/controllers/metrics_controller_spec.rb`
- Modify: `spec/bigcommerce/prometheus/servers/puma/rack_app_spec.rb`

**Bug:** `MetricsController#metrics` calls `Timeout.timeout(@timeout)` but `@timeout` is never set — `RackApp#handle` does not pass `timeout:` to the controller. `Timeout.timeout(nil)` runs without any time limit, silently defeating the scrape timeout.

- [ ] **Step 1: Create the stacked GitButler branch**

```bash
but branch new ENGP-429-fix-timeout-passthrough --anchor ENGP-429-fix-gzip-double-metrics
```

- [ ] **Step 2: Write the failing tests**

Add to `spec/bigcommerce/prometheus/servers/puma/controllers/metrics_controller_spec.rb` inside `describe '#call'`:

```ruby
context 'when a timeout is configured' do
  let(:controller) do
    described_class.new(
      request: request,
      response: response,
      server_metrics: server_metrics,
      collector: collector,
      logger: logger,
      timeout: 5
    )
  end

  it 'passes the timeout to Timeout.timeout' do
    expect(Timeout).to receive(:timeout).with(5).and_call_original
    controller.call
  end
end
```

Add to `spec/bigcommerce/prometheus/servers/puma/rack_app_spec.rb` inside `describe '#call'` for the `/metrics` route context:

```ruby
context 'when a timeout is configured on the app' do
  let(:timeout) { 7 }
  let(:app) { described_class.new(collector: collector, timeout: timeout, logger: logger) }

  it 'passes the timeout value to the metrics controller' do
    expect(Bigcommerce::Prometheus::Servers::Puma::Controllers::MetricsController).to receive(:new)
      .with(hash_including(timeout: timeout))
      .and_call_original
    app.call(env)
  end
end
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
bundle exec rspec spec/bigcommerce/prometheus/servers/puma/controllers/metrics_controller_spec.rb \
                  spec/bigcommerce/prometheus/servers/puma/rack_app_spec.rb -f doc
```

Expected: FAIL — `ArgumentError: unknown keyword: :timeout` for BaseController (timeout not accepted) and the controller assertion fails

- [ ] **Step 4: Apply the fix — BaseController accepts timeout**

In `lib/bigcommerce/prometheus/servers/puma/controllers/base_controller.rb`, add `timeout:` to the constructor:

```ruby
def initialize(request:, response:, server_metrics:, collector:, logger:, timeout: nil)
  @request = request
  @response = response
  @collector = collector
  @server_metrics = server_metrics
  @logger = logger
  @timeout = timeout
end
```

- [ ] **Step 5: Apply the fix — RackApp passes timeout**

In `lib/bigcommerce/prometheus/servers/puma/rack_app.rb`, update `handle` to pass `timeout:`:

```ruby
def handle(controller:, request:, response:)
  con = controller.new(
    request: request,
    response: response,
    server_metrics: @server_metrics,
    collector: @collector,
    logger: @logger,
    timeout: @timeout
  )
  con.handle
end
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
bundle exec rspec spec/bigcommerce/prometheus/servers/puma/controllers/metrics_controller_spec.rb \
                  spec/bigcommerce/prometheus/servers/puma/rack_app_spec.rb -f doc
```

Expected: all examples pass

- [ ] **Step 7: Run full suite**

```bash
bundle exec rspec
```

Expected: all examples pass

- [ ] **Step 8: Commit**

```bash
but commit ENGP-429-fix-timeout-passthrough -m "fix(metrics_controller): pass timeout from RackApp through to MetricsController

RackApp held @timeout from config but never passed it to the
controller. Timeout.timeout(nil) blocks forever — the scrape timeout
was silently disabled. Add timeout: to BaseController and thread it
through RackApp#handle.

Refs: ENGP-429"
```

---

## Final Step: Push all branches and open PRs

After all 6 tasks are complete and all branches are committed:

- [ ] **Push all branches**

```bash
but push ENGP-429-fix-env-var
but push ENGP-429-fix-run-thread
but push ENGP-429-fix-collector-thread
but push ENGP-429-fix-queues-nil
but push ENGP-429-fix-gzip-double-metrics
but push ENGP-429-fix-timeout-passthrough
```

- [ ] **Open PRs for each branch**

Each PR targets its parent branch (not main), forming the stack:

```bash
but pr new ENGP-429-fix-env-var
but pr new ENGP-429-fix-run-thread
but pr new ENGP-429-fix-collector-thread
but pr new ENGP-429-fix-queues-nil
but pr new ENGP-429-fix-gzip-double-metrics
but pr new ENGP-429-fix-timeout-passthrough
```

- [ ] **Verify stack in but status**

```bash
but status
```

Expected: 6 branches shown as a stack, each with 1 commit ahead of its parent.
