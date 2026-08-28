# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Stripe
      # Records an already-verified crypto transfer as a Stripe PaymentIntent.
      class CryptoPaymentRecorder
        RAW_UNITS_PER_CENT = 10_000

        def initialize(client:, network:, metadata: nil)
          @client = client
          @network = network
          @metadata = metadata
        end

        def call(payload)
          reference = payload[:receipt]&.reference
          return unless reference.is_a?(String)

          amount = Integer(payload.fetch(:request).fetch("amount"))
          cents = (amount + (RAW_UNITS_PER_CENT / 2)) / RAW_UNITS_PER_CENT
          return if cents < 1

          params = {
            amount: cents,
            currency: "usd",
            confirm: true,
            payment_method_data: {type: "crypto"},
            payment_method_types: ["crypto"],
            payment_method_options: {
              crypto: {
                mode: "transaction_verification",
                transaction_verification_options: {network: @network, transaction_hash: reference}
              }
            }
          }
          metadata = @metadata.is_a?(Hash) ? @metadata.transform_values(&:to_s) : {}
          params[:metadata] = metadata.merge("machine_payment" => "true")

          @client.v1.payment_intents.create(
            params,
            {stripe_version: Defaults::MACHINE_PAYMENTS_API_VERSION, idempotency_key: reference}
          )
        rescue => error
          Kernel.warn(
            "[stripe] failed to record crypto payment " \
              "network=#{@network.inspect} transaction_hash=#{reference.inspect}: #{error.class}: #{error.message}"
          )
          nil
        end
      end
    end
  end
end
