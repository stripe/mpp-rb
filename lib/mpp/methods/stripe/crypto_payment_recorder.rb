# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Stripe
      # Records an already-settled crypto transfer as a Stripe PaymentIntent.
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

          analytics = AnalyticsMetadata.build(payload.fetch(:challenge))
          options = payload[:payment_intent_options] || {}
          configured_metadata = @metadata.is_a?(Hash) ? @metadata.transform_keys(&:to_s).transform_values(&:to_s) : {}
          optional_metadata = configured_metadata.merge(options.fetch(:metadata, {}))
          required_params = {
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
            },
            metadata: analytics
          }
          params = required_params.dup
          params[:customer] = options[:customer] if options.key?(:customer)
          params[:hooks] = options[:hooks] if options.key?(:hooks)
          params[:receipt_email] = options[:receipt_email] if options.key?(:receipt_email)
          params[:metadata] = analytics.merge(optional_metadata)
          has_optional_params = payload[:has_payment_intent_options] || !optional_metadata.empty?

          create(params, reference)
        rescue => error
          if defined?(required_params) && has_optional_params && definitive_invalid_request?(error)
            Kernel.warn(
              "[stripe] optional PaymentIntent recording fields were rejected; retrying without them: " \
                "#{error.class}: #{error.message}"
            )
            begin
              return create(required_params, "#{reference}_fallback")
            rescue => fallback_error
              error = fallback_error
            end
          end

          Kernel.warn(
            "[stripe] failed to record crypto payment " \
              "network=#{@network.inspect} transaction_hash=#{reference.inspect}: #{error.class}: #{error.message}"
          )
          nil
        end

        private

        def create(params, idempotency_key)
          @client.v1.payment_intents.create(
            params,
            {stripe_version: Defaults::MACHINE_PAYMENTS_API_VERSION, idempotency_key: idempotency_key}
          )
        end

        def definitive_invalid_request?(error)
          return true if defined?(::Stripe::InvalidRequestError) && error.is_a?(::Stripe::InvalidRequestError)
          return true if error.respond_to?(:type) && error.type == "StripeInvalidRequestError"
          return true if error.respond_to?(:error) && error.error.respond_to?(:type) && error.error.type == "invalid_request_error"

          false
        end
      end
    end
  end
end
