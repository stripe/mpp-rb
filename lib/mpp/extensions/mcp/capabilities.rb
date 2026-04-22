# typed: strict
# frozen_string_literal: true

module Mpp
  module Extensions
    module MCP
      extend T::Sig

      module_function

      # Build payment capabilities object for MCP.
      sig { params(methods: T.untyped, intents: T.untyped).returns(T::Hash[T.untyped, T.untyped]) }
      def payment_capabilities(methods, intents)
        {
          "payment" => {
            "methods" => methods,
            "intents" => intents
          }
        }
      end
    end
  end
end
