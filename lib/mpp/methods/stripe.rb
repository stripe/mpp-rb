# typed: strict
# frozen_string_literal: true

module Mpp
  module Methods
    module Stripe
      extend T::Sig

      autoload :Defaults, "mpp/methods/stripe/defaults"
      # Eagerly require stripe_method so the Stripe.stripe factory method is available
      require_relative "stripe/stripe_method"
      autoload :ChargeIntent, "mpp/methods/stripe/charge_intent"
      autoload :ClientMethod, "mpp/methods/stripe/client_method"
      autoload :CryptoPaymentRecorder, "mpp/methods/stripe/crypto_payment_recorder"
      autoload :AnalyticsMetadata, "mpp/methods/stripe/analytics_metadata"
      autoload :MachinePayments, "mpp/methods/stripe/machine_payments"
      autoload :PaymentIntentMethod, "mpp/methods/stripe/payment_intent_method"
      autoload :PaymentIntentOptions, "mpp/methods/stripe/payment_intent_options"

      sig do
        params(
          network_id: String,
          livemode: T::Boolean,
          client: T.untyped,
          deposit_addresses: T.untyped,
          metadata: T.untyped
        ).returns(MachinePayments)
      end
      def self.create(network_id:, livemode:, client:, deposit_addresses: nil, metadata: nil)
        MachinePayments.new(
          network_id: network_id,
          livemode: livemode,
          client: client,
          deposit_addresses: deposit_addresses,
          metadata: metadata
        )
      end
    end
  end
end
