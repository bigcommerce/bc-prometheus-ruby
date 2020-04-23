Changelog for the bc-prometheus-ruby gem.

### Pending Release

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
