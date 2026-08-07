# bc-prometheus-ruby - Drop-in Prometheus metrics

[![CircleCI](https://circleci.com/gh/bigcommerce/bc-prometheus-ruby.svg?style=svg&circle-token=fc3e2c4405a1f53a31e298f0ef981c2d0dfdee90)](https://circleci.com/gh/bigcommerce/bc-prometheus-ruby) [![Gem Version](https://badge.fury.io/rb/bc-prometheus-ruby.svg)](https://badge.fury.io/rb/bc-prometheus-ruby) [![Documentation](https://inch-ci.org/github/bigcommerce/bc-prometheus-ruby.svg?branch=main)](https://inch-ci.org/github/bigcommerce/bc-prometheus-ruby?branch=main) [![Maintainability](https://api.codeclimate.com/v1/badges/4a06277c738245e8bac1/maintainability)](https://codeclimate.com/github/bigcommerce/bc-prometheus-ruby/maintainability) [![Test Coverage](https://api.codeclimate.com/v1/badges/4a06277c738245e8bac1/test_coverage)](https://codeclimate.com/github/bigcommerce/bc-prometheus-ruby/test_coverage)

## Installation

```ruby
gem 'bc-prometheus-ruby'
```

Then in your `application.rb`, prior to extending `Rails::Application` or any initializers:

```ruby
require 'bigcommerce/prometheus'
```

Then in your web server config file (e.g. `puma.rb`)

```ruby
before_fork do
  Rails.application.config.before_fork_callbacks.each(&:call)
end
```

You can then view your metrics at: http://0.0.0.0:9394/metrics

## Puma

For extra Puma metrics, add this to `config/puma.rb`:

```ruby
after_worker_fork do
  Rails.application.config.after_fork_callbacks.each(&:call)
end
```

## Resque

In your `task 'resque:setup'` rake task, do: 

```ruby
require 'bigcommerce/prometheus'
Bigcommerce::Prometheus::Instrumentors::Resque.new(app: Rails.application).start
```

### Metrics pushed from inside a job

Resque runs each job in a forked child that ends with `exit!`, which runs no at_exit handlers and does not wait for
threads. Pushing a metric only queues it; delivery happens on a background thread that wakes every
`client_thread_sleep` seconds. A child that pushes and then returns is normally torn down before that thread runs, so
the observation is silently discarded.

Two things are done automatically to make an in-child push arrive:

- The child is given a clean client queue at fork time, via `Resque.after_fork`. Without this it would inherit a copy
  of whatever the parent had not yet drained and have to re-send all of it before reaching its own message.
- The child delivers its own queue on the calling thread before the job returns, by wrapping
  `Resque::Worker#perform`. Delivery is serialised against the background thread, so a request already in progress
  finishes before the child exits rather than being destroyed with it.

Cost is one request to the local collector per job that pushed something, and nothing at all for jobs that pushed
nothing. Disable with `PROMETHEUS_RESQUE_CHILD_FLUSH_ENABLED=0` if a service would rather have the throughput and can
accept the loss.

Note that this applies to metrics your application code pushes from inside a job. The per-job histograms below are
recorded in the parent and never pay this cost.

### Measuring delivery and cost

`bin/resque_fork_bench` forks real children against a real redis and a real listener, and reports how many of the
observations pushed inside a job arrived and how much slower the job got. It needs a redis and takes tens of seconds, so
it is a manual tool rather than part of `script/test`.

```bash
redis-server --port 6399 --save '' --appendonly no --daemonize yes

REDIS_URL=redis://127.0.0.1:6399/15 bin/resque_fork_bench --smoke-test
```

`--smoke-test` sweeps a representative spread of job shapes. A single shape can be measured directly instead, varying
how many metrics the job pushes, how much work separates them, and how much work follows the last one:

```bash
bin/resque_fork_bench --pushes 2 --gap 0.05      # two pushes, 50ms apart
bin/resque_fork_bench --pushes 1 --trailing 0.01 # one push, then 10ms of work
bin/resque_fork_bench --smoke-test --no-child-flush
```

Read the total column rather than the overhead column. Overhead subtracts a control run that performed the same sleeps,
so it hides any part of a wait that overlapped the job's own work. `--help` lists the rest, including
`--thread-sleep` for the drain cadence and `--redis-url`. Exits non-zero if any row lost an observation or exceeded the
overhead budget the integration specs enforce.

### Per-job metrics (opt-in)

Set `PROMETHEUS_RESQUE_PER_JOB_METRICS_ENABLED=1` on Resque worker pods to enable two additional histograms recorded from the parent worker process.

- `resque_job_queue_latency_seconds{job_class}` — time from `scheduled_at` (falling back to `enqueued_at`) until a worker picks the job up. Per attempt; retries-with-backoff anchor on `scheduled_at` so the intentional backoff doesn't show as latency.
- `resque_job_perform_duration_seconds{job_class}` — total Resque child lifetime (fork → `Process.waitpid` return). Includes fork overhead, Redis reconnect, after_fork hooks, perform, and exit.

These are off by default because they emit one histogram observation per job per worker pod, which adds cardinality. Opt in per service.

`resque_job_queue_latency_seconds` is supported for jobs enqueued via ActiveJob (`.perform_later`) — the enqueue timestamps come from ActiveJob's serialized payload, and the `job_class` label is the user's job class name, not `ActiveJob::QueueAdapters::ResqueAdapter::JobWrapper`. 
`scheduled_at` is serialized by ActiveJob from Rails 7.1; on older Rails the payload carries only `enqueued_at`, so intentional scheduling/backoff delay counts toward queue latency. 
Vanilla Resque jobs (`Resque.enqueue`) carry no enqueue timestamps, so `queue_latency` silently no-ops for them; `perform_duration` works for every job regardless.

Requires resque >= 1.27 workers running in the default fork-per-job mode — the hooks instrument `Resque::Worker#perform_with_fork`. Non-forking workers (`FORK_PER_JOB=false`, or platforms without `fork`) are not instrumented; a warning is logged at worker boot when per-job metrics are enabled but cannot record.

## Configuration

After requiring the main file, you can further configure with:

| Option | Description | Default | Environment Variable |
| ------ | ----------- | ------- | -------------------- |
| client_custom_labels | A hash of custom labels to send with each client request | `{}` | None |
| client_max_queue_size | The max amount of metrics to send before flushing | `10000` | `ENV['PROMETHEUS_CLIENT_MAX_QUEUE_SIZE']` |
| client_thread_sleep | How often to sleep the worker thread that manages the client buffer (seconds) | `0.5` | `ENV['PROMETHEUS_CLIENT_THREAD_SLEEP']` |
| client_open_timeout | Connect timeout when delivering to the collector (seconds) | `0.5` | `ENV['PROMETHEUS_CLIENT_OPEN_TIMEOUT']` |
| client_read_timeout | Response timeout when delivering to the collector (seconds) | `1.0` | `ENV['PROMETHEUS_CLIENT_READ_TIMEOUT']` |
| puma_collection_frequency | How often to poll puma collection metrics (seconds) | `30` | `ENV['PROMETHEUS_PUMA_COLLECTION_FREQUENCY']` |
| server_host | The host to run the exporter on | `"0.0.0.0"` | `ENV['PROMETHEUS_SERVER_HOST']` |
| server_port | The port to run the exporter on | `9394` | `ENV['PROMETHEUS_SERVER_PORT']` |
| server_thread_pool_size | The number of threads used for the exporter server | `3` | `ENV['PROMETHEUS_SERVER_THREAD_POOL_SIZE']` |
| process_name | What the current process name is (used in logging) | `"unknown"` | `ENV['PROCESS']` |
| railtie_disabled | Opt out flag for Railtie; use `Bigcommerce::Prometheus::Instrumentors::Web.new(app: Rails.application).start` in your app's code to start it up yourself  | `0` | `ENV['PROMETHEUS_DISABLE_RAILTIE']` |
| resque_per_job_metrics_enabled | Enable per-job queue-latency and perform-duration histograms (parent-side, no synchronous flush) | `0` | `ENV['PROMETHEUS_RESQUE_PER_JOB_METRICS_ENABLED']` |
| resque_child_flush_enabled | Deliver a forked child's own queued metrics before Resque exits it | `1` | `ENV['PROMETHEUS_RESQUE_CHILD_FLUSH_ENABLED']` |

## Custom Collectors

To create custom metrics and collectors, simply create two files: a collector (the class that runs and collects metrics),
and the type collector, which runs on the threaded prometheus server and 

### Type Collector

First, create a type collector. Note that the "type" of this will be the full name of the class, with `TypeCollector`
stripped. This is important later. Our example here will have a "type" of "app".

```ruby
class AppTypeCollector < ::Bigcommerce::Prometheus::TypeCollectors::Base
  def build_metrics
    {
      honks: PrometheusExporter::Metric::Counter.new('honks', 'Running counter of honks'),
      points: PrometheusExporter::Metric::Gauge.new('points', 'Current amount of points')
    }
  end

  def collect_metrics(data:, labels: {})
    metric(:points).observe(data.fetch('points', 0))
    metric(:honks).observe(1, labels) if data.fetch('honks', 0).to_i.positive?
  end
end
```

There are two important methods here: `build_metrics`, which registers the different metrics you want to measure, and
`collect_metrics`, which actually takes in the metrics and prepares them to be rendered so that Prometheus can scrape
them.

Note also in the example the different ways of observing Gauges vs Counters. 

### Collector

Next, create a collector. Your "type" of the Collector must match the type collector above, so that bc-prometheus-ruby
knows how to map the metrics to the right TypeCollector. This is inferred from the class name. Here, it is "app":

```ruby
class AppCollector < ::Bigcommerce::Prometheus::Collectors::Base
  def honk!
    push(
      honks: 1,
      custom_labels: {
        volume: 'loud'
      }
    )
  end

  def collect(metrics)
    metrics[:points] = rand(1..100)
    metrics
  end
end
```

There are two types of metrics here: on-demand, and polled. Let's look at the first:

#### On-Demand Metrics

To issue an on-demand metric (usually a counter) that then automatically updates, in your application code, you would
then run:

```ruby
app_collector = AppCollector.new
app_collector.honk!
```

This will "push" the metrics to our `AppTypeCollector` instance, which will render them as:

```
# HELP ruby_honks Running counter of honks
# TYPE ruby_honks counter
ruby_honks{volume="loud"} 2
```

As you can see this will respect any custom labels we push in as well.

### Polling Metrics

Using our same AppCollector, if you note the `collect` method: this method will run on a 15 second polled basis
(the frequency of which is configurable in the initializer of the AppCollector). Here we're just spitting out random
points, so it'll look something like this:

```
# HELP ruby_points Current amount of points
# TYPE ruby_points gauge
ruby_points 42
```

### Registering Our Collectors

Each different type of integration will need to have the collectors passed into them, where appropriate. For example,
if we want these collectors to run on our web, resque, and hutch processes, we'll need to:

```ruby
::Bigcommerce::Prometheus.configure do |c|
  c.web_collectors = [AppCollector]
  c.web_type_collectors = [AppTypeCollector.new]
  c.resque_collectors = [AppCollector]
  c.resque_type_collectors = [AppTypeCollector.new]
  c.hutch_collectors = [AppCollector]
  c.hutch_type_collectors = [AppTypeCollector.new]
end
```

#### Custom Server Integrations

For custom integrations that initialize their own server, you'll need to pass your TypeCollector instance via the 
`.add_type_collector` method on the prometheus server instance before starting it:

```ruby
server = ::Bigcommerce::Prometheus::Server.new
Bigcommerce::Prometheus.web_type_collectors.each do |tc|
  server.add_type_collector(tc)
end

# and for polling:

AppCollector.start
```

## License

Copyright (c) 2019-present, BigCommerce Pty. Ltd. All rights reserved 

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated 
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the 
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit 
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the 
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE 
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR 
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR 
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
