Changelog for the bc-prometheus-ruby gem.

## 0.9.1

- Reset the Prometheus client in forked Resque children, by wrapping `Resque::Worker#perform`. A child previously inherited a copy of the parent's undrained outbound queue and had to re-send every message in it before reaching its own, which Resque's `exit!` cut short. Observations pushed from inside a job were dropped as a result. `Worker#perform` is what runs the `after_fork` hooks, so the reset lands ahead of every one of them: an application hook that records a metric and was registered before this integration started would otherwise have had its observation enqueued and then discarded. The reset only runs in a forked child, identified by a changed pid, so a non-forking worker keeps the queue it is still responsible for sending.
- Optionally deliver a forked Resque child's own queued metrics before the child exits, by wrapping `Resque::Worker#perform`. Pushing only queues, and `exit!` does not wait for the thread that would deliver it, so metrics recorded inside a job were unreliable regardless of the above. Drains whichever client `Integrations::Resque.start` was given, so the queue delivered is the one the reset cleared. **Off by default**, because it costs one request per observation a job records, each queued message being sent separately, and upgrading the gem should not change how long anyone's jobs take. Enable with `PROMETHEUS_RESQUE_CHILD_FLUSH_ENABLED=1`. Jobs that record nothing pay nothing either way.
- Accept a callable for `resque_child_flush_enabled`, asked in the parent before every fork so the child inherits the answer and never evaluates anything itself. Lets the flush be driven by a feature flag, per process or per job, without a restart and without the gem depending on any flag service. A callable taking an argument receives the `Resque::Job`. Anything it raises is treated as "do not flush", since it runs as a `Resque.before_fork` hook where an escaping exception would stop the worker. The env var supplies the default and an assignment overrides it, as with every other setting, so a callable replaces the env var rather than layering on top of it.
- Serialise delivery to the collector on its own mutex, so a flush cannot return while the background thread still has a message in flight. An empty queue is not an empty wire: the worker thread pops before it sends, and a child exiting in that window destroyed the request. Also removes a hang where both threads saw one queued message, both called `pop`, and the loser blocked forever.
- Bound a flush to `PROMETHEUS_CLIENT_FLUSH_TIMEOUT`, 20ms by default, covering the wait for the delivery lock as well as the requests. A forked child holds up real work while it delivers, so an unhealthy collector now costs it a known amount rather than however long the network takes to give up. Past the deadline the observations are abandoned, because availability of the work matters more than completeness of its metrics. `Net::HTTP` caps connect, write and read separately rather than bounding a request as a whole, so per-request timeouts alone would let one slow message overrun the budget several times over. The flush therefore runs on a thread that is stopped once the budget is spent, which holds the wall clock to the configured value rather than a multiple of it.
- Report abandoned observations, and push the warning out of the process before `exit!` destroys it. A line written to a buffered STDOUT in a Resque child never reaches the log, so the buffers are flushed after warning rather than left to an exit that runs no handlers. `flush!` returns `:empty`, `:success`, `:timeout` or `:error`, and the report is driven by that rather than by the queue length alone: a flush that cannot take the delivery lock leaves an empty queue while the background thread is still sending, so counting the queue reported nothing lost in the one case where the process is about to destroy a request.

## 0.9.0

- Add `Bigcommerce::Prometheus::Instrumentors::Protorabbit` so protorabbit (RabbitMQ protobuf consumer) processes run an embedded Prometheus exporter server, fixing dropped/refused metric pushes (`Errno::ECONNREFUSED` on `/send-metrics`) from those processes.

## 0.8.3

- Add opt-in per-Resque-job histograms `resque_job_queue_latency_seconds` and `resque_job_perform_duration_seconds`, labelled by `job_class`.

## 0.8.2

- Add `version=0.0.4` to `Content-Type` header for Prometheus exposition format 0.0.4 compliance

## 0.8.1

- Prometheus client respects the enabled setting
- Upgrade prometheus_exporter
- Expose SQL metrics for different dashboards

## 0.8.0

- Add support for Ruby 3.4
- Drop support for Ruby 3.0, 3.1

## 0.7.0

- Add CI suite for Ruby 3.3
- Update README for starting prometheus with Puma
- Add logging with prometheus server starts
- Migrate from thin to puma as the web server

## 0.6.0

- Add support for Ruby 3.1/3.2
- Drop support for Ruby 2
- Add CodeClimate analysis

## 0.5.2

- Better error handling post-fork for web/resque instrumentors
- Fix issue with using `Collectors::Base` and keyword arguments in Ruby 2.7
- Remove null-logger development dependency

### 0.5.1

- Fix keywords argument issue with Collectors::Base and Ruby 3.0+

### 0.5.0

- Add configuration to disable the Railtie that activates the web instrumentor automatically. This allows applications to choose how and when this is initialized.
- Bump prometheus_exporter gem
- Start testing against Ruby 3.0

### 0.4.0

- Add configuration to control Thin web server thread pool size. Note that the default number of threads is changing from 20 to 3. You can configure this using an environment variable or initializer.
- Update rubocop to 1.0

### 0.3.1

- Update prometheus_exporter dependency to ~> 0.5 to fix memory leaks

### 0.3.0

- Support for only Ruby 2.6+ going forward
- Updated README around custom metrics and collectors
- Add ability to pass custom resque and hutch Collectors/TypeCollectors
- Add ENV support for all configuration elements
- Fix issue where base collector did not use Bigcommerce::Prometheus.client
- Expose new `push` method for Collectors::Base to ease use of custom ad hoc metrics

### 0.2.4

- Fix cant modify frozen array error when using bc-prometheus-ruby outside a web process
  but within rails

### 0.2.3

- Set default STDOUT logger to INFO level
- Fix bug with resque type collector

### 0.2.2

- Fix missing inheritance for resque collector

### 0.2.1

- Prevent starting of Puma integration if Puma is not loaded

### 0.2.0

- Add the ability to pass custom collectors and type collectors to the web instrumenter
- Add base collector and type collector classes for ease of development of custom integrations
- Change railtie to after initialization to allow for customization

### 0.1.5

- Fix issue where puma collector was not being registered on the server

### 0.1.4

- Handle circumstances when before_fork_callbacks is called outside of the web process

### 0.1.3

- Move to bigcommerce fork of multitrap to handle IGNORE clauses more cleanly

### 0.1.1

- Add multitrap to more cleanly handle trap signals
- Use proc in signal handlers for consistent trap handling

### 0.1.0

- Replace WEBrick server from PrometheusExporter with Thin server implementation to reduce memory leakage
- Utilize NET::HTTP instead of direct sockets to prevent bad socket errors

### 0.0.5

- Add resque instrumentation

### 0.0.4

- Properly handle SIGINT/SIGTERM to shutdown prometheus exporter
- Add process names to log output for easier debugging

### 0.0.3

- Add hutch instrumentor for hutch / rmq support

### 0.0.2

- Better support for older Rails / Puma versions
- Adds basic support for non-Rails applications

### 0.0.1

- Initial public release
