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

        def initialize(secret_key:, api_base: Defaults::STRIPE_API_BASE)
          @name = "charge"
          @secret_key = secret_key
          @api_base = api_base
        end

        def verify(credential, request)
          # Check challenge expiry
          challenge_expires = credential.challenge.expires
          if challenge_expires
            expires = Time.iso8601(challenge_expires.gsub("Z", "+00:00"))
            raise Mpp::VerificationError, "Request has expired" if expires < Time.now.utc
          end

          payload_data = credential.payload
          unless payload_data.is_a?(Hash) && payload_data.key?("spt")
            raise Mpp::VerificationError, "Invalid credential payload: missing spt"
          end

          spt = payload_data["spt"]
          external_id = payload_data["externalId"]

          # Build PaymentIntent params
          params = {
            amount: Integer(request["amount"]),
            currency: request["currency"],
            shared_payment_granted_token: spt,
            confirm: true,
            automatic_payment_methods: {
              enabled: true,
              allow_redirects: "never"
            }
          }

          # Include metadata from methodDetails if present
          method_details = request["methodDetails"]
          if method_details.is_a?(Hash) && method_details["metadata"].is_a?(Hash)
            params[:metadata] = method_details["metadata"].transform_values(&:to_s)
          end

          # Create PaymentIntent via Stripe SDK
          begin
            Kernel.require "stripe"
          rescue LoadError
            raise "stripe gem is required for Stripe charge verification. Install with: gem install stripe"
          end

          begin
            client = ::Stripe::StripeClient.new(@secret_key)
            result = client.v1.payment_intents.create(params)
          rescue => e
            raise Mpp::VerificationError, e.message
          end

          # https://docs.stripe.com/error-low-level#idempotency
          if result.respond_to?(:last_response) &&
              result.last_response&.headers&.[]("idempotent-replayed") == "true"
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

          Mpp::Receipt.success(pi_id, method: "stripe", external_id: external_id)
        end
      end
    end
  end
end
