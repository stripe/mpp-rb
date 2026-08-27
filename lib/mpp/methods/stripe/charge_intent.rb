# typed: false
# frozen_string_literal: true

require "time"

module Mpp
  module Methods
    module Stripe
      # Default settlement via the public Stripe API. Used when `secret_key:` is
      # passed to ChargeIntent / Stripe.stripe.
      class StripeApiSettle
        def initialize(secret_key:, api_base: Defaults::STRIPE_API_BASE, client: nil)
          @secret_key = secret_key
          @api_base = api_base
          @client = client
        end

        def call(amount:, currency:, spt:, payment_method_types:, idempotency_key:, metadata: nil)
          unless @client
            begin
              Kernel.require "stripe"
            rescue LoadError
              raise "stripe gem is required for Stripe charge verification. Install with: gem install stripe"
            end
          end

          params = {
            amount: amount,
            currency: currency,
            shared_payment_granted_token: spt,
            confirm: true,
            payment_method_types: payment_method_types
          }
          params[:metadata] = metadata if metadata

          client = @client || ::Stripe::StripeClient.new(@secret_key)
          client.v1.payment_intents.create(params, {idempotency_key: idempotency_key})
        end
      end

      # Server-side charge intent that verifies payment via Stripe PaymentIntents.
      #
      # Pass `secret_key:` to charge through the public Stripe API, or `settle:`
      # to supply your own PaymentIntent create (callable or object with #settle).
      class ChargeIntent
        attr_reader :name

        def initialize(secret_key: nil, api_base: Defaults::STRIPE_API_BASE, client: nil, settle: nil)
          @name = "charge"
          @settle = resolve_settle(secret_key: secret_key, api_base: api_base, client: client, settle: settle)
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

          metadata = if method_details["metadata"].is_a?(Hash)
            method_details["metadata"].transform_values(&:to_s)
          end

          begin
            result = invoke_settle(
              amount: Integer(request["amount"]),
              currency: request["currency"],
              spt: spt,
              payment_method_types: payment_method_types,
              idempotency_key: stripe_idempotency_key(credential),
              metadata: metadata
            )
          rescue Mpp::VerificationError, Mpp::PaymentActionRequiredError, Mpp::InvalidChallengeError
            raise
          rescue => e
            raise Mpp::VerificationError, e.message
          end

          pi_id, status, replayed = extract_result(result)

          raise Mpp::VerificationError, "Payment has already been processed." if replayed

          if status.to_s == "requires_action"
            raise Mpp::PaymentActionRequiredError.new(reason: "PaymentIntent #{pi_id} requires action")
          end

          unless status.to_s == "succeeded"
            raise Mpp::VerificationError, "PaymentIntent #{pi_id} has status: #{status}"
          end

          Mpp::Receipt.success(pi_id, method: "stripe", external_id: request_external_id)
        end

        private

        def resolve_settle(secret_key:, api_base:, client:, settle:)
          if settle
            raise ArgumentError, "pass settle or secret_key, not both" unless secret_key.nil?
            raise ArgumentError, "pass settle or client, not both" unless client.nil?
            unless settle.respond_to?(:call) || settle.respond_to?(:settle)
              raise ArgumentError, "settle must be callable or respond to #settle"
            end
            return settle
          end

          return StripeApiSettle.new(secret_key: secret_key, api_base: api_base, client: client) if client

          if secret_key.nil? || secret_key.to_s.empty?
            raise ArgumentError, "secret_key or settle is required"
          end

          StripeApiSettle.new(secret_key: secret_key, api_base: api_base)
        end

        def invoke_settle(params)
          if !@settle.is_a?(Proc) && @settle.respond_to?(:settle)
            @settle.settle(**params)
          else
            @settle.call(**params)
          end
        end

        def extract_result(result)
          if result.is_a?(Hash)
            id = result[:id] || result["id"]
            status = result[:status] || result["status"]
            replayed = result[:replayed] || result["replayed"]
          elsif result.nil?
            raise Mpp::VerificationError, "settle must return an id and status"
          else
            id = result.respond_to?(:id) ? result.id : nil
            status = result.respond_to?(:status) ? result.status : nil
            replayed = if result.respond_to?(:replayed)
              result.replayed
            else
              stripe_replayed?(result)
            end
          end

          raise Mpp::VerificationError, "settle must return an id and status" if id.nil? || status.nil?

          [id, status, replayed == true || replayed == "true"]
        end

        def stripe_replayed?(result)
          result.respond_to?(:last_response) &&
            result.last_response&.headers&.[]("idempotent-replayed") == "true"
        end

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
