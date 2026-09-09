# typed: strict
# frozen_string_literal: true

module Mpp
  module Server
    # Method interface (duck type):
    #   name       -> String
    #   intents    -> Hash[String, Intent]
    #   create_credential(challenge) -> Credential
    #   on_payment_success -> optional callable receiving a payment.success payload

    module MethodHelper
      extend T::Sig

      module_function

      # Transform request using method's transform_request if available.
      sig { params(method: T.untyped, request: T::Hash[String, T.untyped], credential: T.untyped).returns(T::Hash[String, T.untyped]) }
      def transform_request(method, request, credential)
        if method.respond_to?(:transform_request)
          method.transform_request(request, credential)
        else
          request
        end
      end

      # Give a method a chance to create a request-scoped intent view and to
      # remove private server input before the canonical request is built.
      sig { params(method: T.untyped, intent: T.untyped, input: T::Hash[Symbol, T.untyped]).returns([T.untyped, T::Hash[Symbol, T.untyped]]) }
      def prepare_intent(method, intent, input)
        return [intent, input] unless method.respond_to?(:prepare_intent)

        prepared = method.prepare_intent(intent, input)
        unless prepared.is_a?(Array) && prepared.length == 2 && prepared[1].is_a?(Hash)
          Kernel.raise ArgumentError, "prepare_intent must return [intent, request_input]"
        end

        [prepared[0], prepared[1]]
      end

      # Check whether a method should be advertised for a canonical request.
      # This only governs composing new 402 offers, never credential redemption.
      sig { params(method: T.untyped, request: T::Hash[String, T.untyped]).returns(T::Boolean) }
      def can_offer?(method, request)
        return true unless method.respond_to?(:can_offer?)

        available = method.can_offer?(request)
        unless available == true || available == false
          Kernel.raise ArgumentError, "can_offer? must return true or false"
        end

        available
      end
    end
  end
end
