# typed: false
# frozen_string_literal: true

require "time"

module Mpp
  module Methods
    module Stripe
      # Server-side charge intent that verifies payment via Stripe PaymentIntents.
      # Requires the `stripe` gem.
      class ChargeIntent
        attr_reader :name

        def initialize(secret_key:, api_base: Defaults::STRIPE_API_BASE, client: nil,
          payment_intent_options: nil)
          @name = "charge"
          @secret_key = secret_key
          @api_base = api_base
          @client = client
          @payment_intent_options = payment_intent_options
        end

        def with_payment_intent_options(payment_intent_options)
          self.class.new(
            secret_key: @secret_key,
            api_base: @api_base,
            client: @client,
            payment_intent_options: payment_intent_options
          )
        end

        def verify(credential, request)
          # Check challenge expiry
          challenge_expires = credential.challenge.expires
          if challenge_expires
            expires = Time.iso8601(challenge_expires.gsub("Z", "+00:00"))
            raise Mpp::VerificationError, "Request has expired" if expires < Time.now.utc
          end

          payload_data = credential.payload
          spt = payload_data["spt"] if payload_data.is_a?(Hash)
          unless spt.is_a?(String) && !spt.empty?
            raise Mpp::VerificationError, "Invalid credential payload: missing or invalid spt"
          end

          credential_external_id = payload_data["externalId"]
          request_external_id = request["externalId"]
          if !request_external_id.nil? && credential_external_id != request_external_id
            raise Mpp::InvalidChallengeError.new(
              challenge_id: credential.challenge.id,
              reason: "credential externalId does not match request externalId"
            )
          end

          method_details = request["methodDetails"]
          method_details = {} unless method_details.is_a?(Hash)

          # Enforce the payment method types allowlist from the challenge
          payment_method_types = method_details["paymentMethodTypes"]
          unless payment_method_types.is_a?(Array) &&
              payment_method_types.any? &&
              payment_method_types.all? { |type| type.is_a?(String) && !type.strip.empty? }
            raise Mpp::VerificationError, "Invalid or missing methodDetails.paymentMethodTypes"
          end

          payment_intent_options = PaymentIntentOptions.resolve(
            @payment_intent_options,
            challenge: credential.challenge,
            credential: credential,
            request: request
          ) || {}

          # Build PaymentIntent params
          params = {
            amount: Integer(request["amount"]),
            currency: request["currency"],
            shared_payment_granted_token: spt,
            confirm: true,
            payment_method_types: payment_method_types
          }

          params[:customer] = payment_intent_options[:customer] if payment_intent_options.key?(:customer)
          params[:hooks] = payment_intent_options[:hooks] if payment_intent_options.key?(:hooks)
          params[:receipt_email] = payment_intent_options[:receipt_email] if payment_intent_options.key?(:receipt_email)

          metadata = method_details["metadata"].is_a?(Hash) ? method_details["metadata"].transform_values(&:to_s) : {}
          params[:metadata] = AnalyticsMetadata.build(credential.challenge)
            .merge(metadata)
            .merge(payment_intent_options.fetch(:metadata, {}))

          unless @client
            begin
              Kernel.require "stripe"
            rescue LoadError
              raise "stripe gem is required for Stripe charge verification. Install with: gem install stripe"
            end
          end

          begin
            client = @client || ::Stripe::StripeClient.new(@secret_key)
            result = client.v1.payment_intents.create(
              params,
              {stripe_version: Defaults::MACHINE_PAYMENTS_API_VERSION, idempotency_key: stripe_idempotency_key(credential)}
            )
          rescue => e
            raise Mpp::VerificationError, e.message
          end

          # https://docs.stripe.com/error-low-level#idempotency
          last_response = result.last_response if result.respond_to?(:last_response)
          response_headers = last_response.respond_to?(:http_headers) ? last_response.http_headers : last_response&.headers
          if response_headers&.[]("idempotent-replayed") == "true"
            raise Mpp::VerificationError, "Payment has already been processed."
          end

          pi_id = result.id
          status = result.status

          if status == "requires_action"
            raise Mpp::PaymentActionRequiredError.new(reason: "PaymentIntent #{pi_id} requires action")
          end

          unless status == "succeeded"
            raise Mpp::VerificationError, "PaymentIntent #{pi_id} has status: #{status}"
          end

          Mpp::Receipt.success(pi_id, method: "stripe", external_id: request_external_id)
        end

        private

        # Include the SPT so a retry with a fresh token is a new PaymentIntent,
        # matching mppx (`prefix_challengeId_spt`). Same challenge + same SPT
        # still collapses via Stripe idempotency.
        def stripe_idempotency_key(credential)
          "mpp_#{credential.challenge.id}_#{credential.payload["spt"]}"
        end
      end
    end
  end
end
