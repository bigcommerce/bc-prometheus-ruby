Changelog for the bc-prometheus-ruby gem.

h3. Pending Release

h3. 0.0.6

- Switch railtie to `after_initialize` from `initializer`. This allows initializer configuration of the client.

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
