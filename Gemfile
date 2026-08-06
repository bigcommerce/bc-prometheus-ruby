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
source 'https://rubygems.org'

gem 'bundler-audit', '>= 0.6'
gem 'pry', '>= 0.12'
gem 'rspec', '>= 3.8'
gem 'rspec_junit_formatter', '>= 0.4'
gem 'rubocop', '>= 1.0'
gem 'rubocop-performance', '>= 1.5'
gem 'rubocop-rspec'
gem 'simplecov', '>= 0.16'

# Resque is an optional integration, but its fork-per-job lifecycle is the one thing the client has to survive, so the
# integration needs real coverage rather than stubs.
#
# Resque depends on sinatra for its web UI with a loose `>= 0.9.2`. There is no Gemfile.lock in this repo, so CI
# resolves cold and the resolver is free to pick an old sinatra that caps `rack < 3`, which conflicts with the
# gemspec's `rack >= 3.0`. Pinning sinatra forward keeps the resolution rack-3 compatible.
gem 'resque', '>= 2.0'
gem 'sinatra', '>= 4.0'

gemspec
