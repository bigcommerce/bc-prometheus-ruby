Changelog for the bc-prometheus-ruby gem.

h3. Pending Release

h3. 0.1.4

- Handle circumstances when before_fork_callbacks is called outside of the web process

h3. 0.1.3

- Move to bigcommerce fork of multitrap to handle IGNORE clauses more cleanly

h3. 0.1.1

- Add multitrap to more cleanly handle trap signals
- Use proc in signal handlers for consistent trap handling

h3. 0.1.0

- Replace WEBrick server from PrometheusExporter with Thin server implementation to reduce memory leakage
- Utilize NET::HTTP instead of direct sockets to prevent bad socket errors

h3. 0.0.5

- Add resque instrumentation

h3. 0.0.4

- Properly handle SIGINT/SIGTERM to shutdown prometheus exporter
- Add process names to log output for easier debugging

h3. 0.0.3

- Add hutch instrumentor for hutch / rmq support

h3. 0.0.2

- Better support for older Rails / Puma versions
- Adds basic support for non-Rails applications

h3. 0.0.1

- Initial public release
