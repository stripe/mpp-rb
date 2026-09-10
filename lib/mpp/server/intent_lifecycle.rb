# typed: strict
# frozen_string_literal: true

module Mpp
  module Server
    # Dispatches an intent through its optional two-phase lifecycle.
    #
    # Two-phase intents expose separate non-mutating validation and terminal
    # payment operations:
    #   validate(credential, request) -> Mpp::Validation
    #   broadcast(credential, request) -> Receipt
    #
    # Broadcast receives the original inputs rather than trusting a prior
    # validation result, matching mppx's re-validation behavior.
    #
    # Intents that only implement the deprecated #verify API continue to work
    # through the legacy path.
    module IntentLifecycle
      extend T::Sig

      module_function

      sig { params(intent: T.untyped, credential: Mpp::Credential, request: T::Hash[String, T.untyped]).returns(Mpp::Receipt) }
      def call(intent, credential, request)
        has_validate = intent.respond_to?(:validate)
        has_broadcast = intent.respond_to?(:broadcast)

        if has_validate != has_broadcast
          Kernel.raise ArgumentError, "intent must implement both #validate and #broadcast"
        end

        if has_validate
          intent.validate(credential, request)
          intent.broadcast(credential, request)
        else
          intent.verify(credential, request)
        end
      end
    end
  end
end
