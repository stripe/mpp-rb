# typed: false
# frozen_string_literal: true

require_relative "defaults"

module Mpp
  module Methods
    module Stripe
      # Stripe payment method implementation.
      # Handles SPT-based payments through Stripe's Business Network.
      class StripeMethod
        attr_reader :name, :currency, :recipient, :decimals, :on_payment_success
        attr_accessor :intents

        def initialize(secret_key:, network_id:, payment_methods: nil,
          metadata: nil, currency: Defaults::DEFAULT_CURRENCY,
          decimals: Defaults::DEFAULT_DECIMALS, external_id: nil,
          on_payment_success: nil, can_offer: nil)
          unless payment_methods.is_a?(Array) &&
              payment_methods.any? &&
              payment_methods.all? { |type| type.is_a?(String) && !type.strip.empty? }
            raise ArgumentError, "payment_methods must be a non-empty array of Stripe payment method type strings"
          end
          unless on_payment_success.nil? || on_payment_success.respond_to?(:call)
            raise ArgumentError, "on_payment_success must be callable"
          end
          unless can_offer.nil? || can_offer.respond_to?(:call)
            raise ArgumentError, "can_offer must be callable"
          end

          @name = "stripe"
          @secret_key = secret_key
          @network_id = network_id
          @payment_methods = payment_methods
          @metadata = metadata
          @external_id = external_id
          @on_payment_success = on_payment_success
          @can_offer = can_offer
          @currency = currency
          @recipient = network_id
          @decimals = decimals
          @intents = {}
        end

        def can_offer?(request)
          return true unless @can_offer

          @can_offer.call(request)
        end

        # Keep Stripe-only request input out of the canonical challenge while
        # retaining it on an isolated SPT intent for terminal verification.
        def prepare_intent(intent, input)
          options_input = input[:payment_intent_options]
          PaymentIntentOptions.validate_input(options_input)
          [intent.with_payment_intent_options(options_input), input.except(:payment_intent_options)]
        end

        # Transform request - injects Stripe-specific methodDetails.
        def transform_request(request, _credential)
          method_details = request.fetch("methodDetails", {})
          method_details = {} unless method_details.is_a?(Hash)

          method_details["networkId"] = @network_id
          method_details["paymentMethodTypes"] = @payment_methods
          method_details["metadata"] = @metadata if @metadata

          transformed = request.merge("methodDetails" => method_details)
          transformed["externalId"] = @external_id if !@external_id.nil? && !transformed.key?("externalId")
          transformed
        end
      end

      # Factory function to create a configured StripeMethod with ChargeIntent.
      def self.stripe(secret_key:, network_id:, payment_methods: nil,
        metadata: nil, currency: Defaults::DEFAULT_CURRENCY,
        decimals: Defaults::DEFAULT_DECIMALS,
        external_id: nil,
        on_payment_success: nil,
        can_offer: nil,
        api_base: Defaults::STRIPE_API_BASE)
        charge_intent = ChargeIntent.new(secret_key: secret_key, api_base: api_base)

        method = StripeMethod.new(
          secret_key: secret_key,
          network_id: network_id,
          payment_methods: payment_methods,
          metadata: metadata,
          currency: currency,
          decimals: decimals,
          external_id: external_id,
          on_payment_success: on_payment_success,
          can_offer: can_offer
        )

        method.intents = {"charge" => charge_intent}
        method
      end
    end
  end
end
