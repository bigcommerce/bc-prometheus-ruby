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
module Bigcommerce
  module Prometheus
    module Integrations
      class Resque
        ##
        # Reads `resque_flush_on_exit_enabled`, which the application can set to one of three things.
        #
        # 1. Falsey: never flush, which is the default.
        # 2. Truthy: flush for every job.
        # 3. Callable: decide per fork, so the application can put the decision behind a feature flag.
        #
        # Nothing here knows about Resque. It answers what the setting says, and `FlushOnExitInstaller` decides what
        # to do about it.
        #
        class FlushOnExitSetting
          ##
          # Read whatever is configured right now. A callable can be replaced at runtime, so the value is not cached
          # beyond the object that holds it.
          #
          # @return [FlushOnExitSetting]
          #
          def self.current
            new(::Bigcommerce::Prometheus.resque_flush_on_exit_enabled)
          end

          ##
          # @param [Object] value The configured setting, which may be a plain value or something callable
          #
          def initialize(value)
            @value = value
          end

          ##
          # Whether the flush is worth installing at all.
          #
          # A callable passes, because the answer it will give is not known until a fork happens.
          #
          # @return [Boolean]
          #
          def possible?
            dynamic? || !!@value
          end

          ##
          # Whether the answer can change between forks, which is true only of a callable.
          #
          # @return [Boolean]
          #
          def dynamic?
            @value.respond_to?(:call)
          end

          ##
          # Whether the child about to be forked should flush.
          #
          # A callable is handed the `Resque::Job` when it accepts one, so the application can decide per job as well
          # as per process. `JobPayload.for(job).job_class` unwraps ActiveJob's payload if the caller wants the real
          # class name.
          #
          # Never raises. The caller is a `Resque.before_fork` hook, so an exception here propagates into
          # `perform_with_fork` and takes down job processing. A flaky feature flag must not be able to stop a worker,
          # so a failure means no flush, which is the asynchronous behavior callers had before this existed.
          #
          # @param [Resque::Job] job
          # @return [Boolean]
          #
          def resolve(job)
            return !!@value unless dynamic?

            !!(arity.zero? ? @value.call : @value.call(job))
          rescue StandardError => e
            ::Bigcommerce::Prometheus.logger&.warn(
              "[bigcommerce-prometheus] resque flush on exit check failed, not flushing this job: #{e}"
            )
            false
          end

          private

          ##
          # Procs answer `arity` themselves. An object with a `#call` method does not, and asking `method(:call).arity`
          # of a proc reports `Proc#call(*args)` as -1, which would hand a job to a callable that takes none. So ask
          # the object first and fall back to its method.
          #
          # @return [Integer]
          #
          def arity
            @value.respond_to?(:arity) ? @value.arity : @value.method(:call).arity
          end
        end
      end
    end
  end
end
