module GraphQL
  class Schema
    # Only calls the underlying resolve if `Time.now` doesn't exceed `max_seconds`
    # since the first field resolution.
    #
    # If it _does_ exceed `max_seconds`, the provided handler
    # will be called _once_ with `type, field, ctx`.
    class TimeoutInstrumentation
      DEFAULT_CONTEXT_KEY = :__timeout_at__

      # @param max_seconds [Integer] Number of seconds to allow the query to run
      # @param context_key [Object] The key in context to store timeout state
      # @yieldparam type [GraphQL::BaseType] The owner of the field which exceeded the timeout
      # @yieldparam field [GraphQL::Field] The field which exceeded the timeout
      # @yieldparam ctx [GraphQL::Query::Context] The context for the field which exceeded the timeout
      def initialize(max_seconds:, context_key: DEFAULT_CONTEXT_KEY, &block)
        @max_seconds = max_seconds
        @context_key = context_key
        @handler = block_given? ? block : DefaultHandler
      end

      def instrument(type, field)
        inner_resolve = field.resolve_proc
        timeout_resolve = TimeoutResolve.new(type, field, max_seconds: @max_seconds, context_key: @context_key, handler: @handler)
        field.redefine(resolve: timeout_resolve)
      end

      # @api private
      class TimeoutState
        def initialize(timeout_at, handler)
          @timeout_at = timeout_at
          @handler = handler
          @handler_was_called = false
        end

        def within_timeout?
          Time.now < @timeout_at
        end

        def call_handler_once(type, field, ctx)
          if !@handler_was_called
            @handler_was_called = true
            @handler.call(type, field, ctx)
          end
        end
      end

      # @api private
      class TimeoutResolve
        attr_reader :inner_resolve

        def initialize(type, field, max_seconds:, context_key:, handler:)
          @type = type
          @field = field
          @inner_resolve = field.resolve_proc
          @max_seconds = max_seconds
          @context_key = context_key
          @handler = handler
        end

        def call(obj, args, ctx)
          timeout = ctx[@context_key] ||= TimeoutState.new(Time.now + @max_seconds, @handler)
          if timeout.within_timeout?
            @inner_resolve.call(obj, args, ctx)
          else
            timeout.call_handler_once(@type, @field, ctx)
          end
        end
      end

      # @api private
      module DefaultHandler
        def self.call(type, field, ctx)
          GraphQL::ExecutionError.new("Timeout on #{type.name}.#{field.name}")
        end
      end
    end
  end
end
