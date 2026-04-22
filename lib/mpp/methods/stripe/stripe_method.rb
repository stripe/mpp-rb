# typed: false
# frozen_string_literal: true

require_relative "defaults"

module Mpp
  module Methods
    module Stripe
      # Stripe payment method implementation.
      # Handles SPT-based payments through Stripe's Business Network.
      class StripeMethod
        attr_reader :name, :currency, :recipient, :decimals
        attr_accessor :intents

        def initialize(secret_key:, network_id:, payment_methods: nil,
          metadata: nil, currency: Defaults::DEFAULT_CURRENCY,
          decimals: Defaults::DEFAULT_DECIMALS)
          @name = "stripe"
          @secret_key = secret_key
          @network_id = network_id
          @payment_methods = payment_methods
          @metadata = metadata
          @currency = currency
          @recipient = network_id
          @decimals = decimals
          @intents = {}
        end

        # Transform request - injects Stripe-specific methodDetails.
        def transform_request(request, _credential)
          method_details = request.fetch("methodDetails", {})
          method_details = {} unless method_details.is_a?(Hash)

          method_details["networkId"] = @network_id
          method_details["paymentMethods"] = @payment_methods if @payment_methods
          method_details["metadata"] = @metadata if @metadata

          request.merge("methodDetails" => method_details)
        end
      end

      # Factory function to create a configured StripeMethod with ChargeIntent.
      def self.stripe(secret_key:, network_id:, payment_methods: nil,
        metadata: nil, currency: Defaults::DEFAULT_CURRENCY,
        decimals: Defaults::DEFAULT_DECIMALS,
        api_base: Defaults::STRIPE_API_BASE)
        charge_intent = ChargeIntent.new(secret_key: secret_key, api_base: api_base)

        method = StripeMethod.new(
          secret_key: secret_key,
          network_id: network_id,
          payment_methods: payment_methods,
          metadata: metadata,
          currency: currency,
          decimals: decimals
        )

        method.intents = {"charge" => charge_intent}
        method
      end
    end
  end
end
