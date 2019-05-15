# bc-prometheus-ruby - Drop-in Prometheus metrics

[![CircleCI](https://circleci.com/gh/bigcommerce/bc-prometheus-ruby/tree/master.svg?style=svg)](https://circleci.com/gh/bigcommerce/bc-prometheus-ruby/tree/master)

## Installation

```ruby
gem 'bc-prometheus-ruby', git: 'git@github.com:bigcommerce/bc-prometheus-ruby'
```

Then in your `application.rb`, prior to extending `Rails::Application` or any initializers:

```ruby
require 'bigcommerce/prometheus'
```

You can then view your metrics at: http://0.0.0.0:9394/metrics

## Puma

For extra Puma metrics, add this to `config/puma.rb`:

```ruby
after_worker_fork do
  Rails.application.config.after_fork_callbacks.each(&:call)
end
```

## Configuration

After requiring the main file, you can further configure with:

| Option | Description | Default |
| ------ | ----------- | ------- |
| client_custom_labels | A hash of custom labels to send with each client request | `{}` |
| client_max_queue_size | The max amount of metrics to send before flushing | 10000 |
| client_thread_sleep | How often to sleep the worker thread that manages the client buffer (seconds) | 0.5 |
| puma_collection_frequency | How often to poll puma collection metrics (seconds) | 30 |
| server_host | The host to run the exporter on | 0.0.0.0 |
| server_port | The port to run the exporter on | 9394 |

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
