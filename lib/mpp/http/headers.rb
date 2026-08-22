# typed: strict
# frozen_string_literal: true

module Mpp
  module Http
    # Shared `{url:, headers:}` helpers used by the x402 facilitator, Tempo fee
    # payer, and Tempo relay HTTP clients.
    #
    # `headers` may be:
    #   * a Hash of static header names/values
    #   * a zero-arity proc returning that Hash
    #   * a proc receiving the request path (or JSON-RPC method) and returning
    #     that Hash
    #   * a nested Hash keyed by operation (`"verify"`, `"broadcast"`, …)
    module Headers
      extend T::Sig

      module_function

      sig { params(url: T.untyped).returns(String) }
      def normalize_base_url(url)
        base = url.to_s
        base = base.chomp("/") while base.end_with?("/")
        base
      end

      sig { params(config: T::Hash[T.untyped, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def symbolize(config)
        config.each_with_object({}) do |(key, value), acc|
          acc[key.to_sym] = value
        end
      end

      sig { params(headers: T.nilable(T::Hash[T.untyped, T.untyped])).returns(T::Hash[String, String]) }
      def stringify(headers)
        return {} if headers.nil?

        headers.each_with_object({}) do |(key, value), acc|
          acc[key.to_s] = value.to_s
        end
      end

      sig { params(source: T.untyped, path: String).returns(T::Hash[String, String]) }
      def resolve(source, path)
        return {} if source.nil?

        if source.respond_to?(:call)
          arity = source.respond_to?(:arity) ? source.arity : 1
          source = (arity == 0) ? source.call : source.call(path)
        end
        return {} unless source.is_a?(Hash)

        operation = path.to_s.delete_prefix("/")
        last = T.let(operation.split("/").last, T.nilable(String))
        keyed = source[operation] || source[operation.to_sym]
        keyed ||= source[last] || source[last.to_sym] if last && last != operation
        stringify(keyed.is_a?(Hash) ? keyed : source)
      end
    end
  end
end
