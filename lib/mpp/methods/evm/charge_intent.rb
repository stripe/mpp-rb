# typed: false
# frozen_string_literal: true

require "time"

module Mpp
  module Methods
    module Evm
      # Server-side EVM charge intent: recover EIP-3009, then settle via facilitator.
      class ChargeIntent
        attr_reader :name, :facilitator, :authorization, :max_timeout_seconds, :route_binding

        def initialize(authorization:, facilitator:, max_timeout_seconds: 300, route_binding: :resource)
          @name = "charge"
          @authorization = authorization
          @facilitator = facilitator
          @max_timeout_seconds = max_timeout_seconds
          @route_binding = route_binding
        end

        def verify(credential, request)
          payload = credential.payload
          unless payload.is_a?(Hash) && payload["type"] == "authorization"
            raise Mpp::VerificationError, "EVM authorization credentials are not supported for this challenge"
          end

          if request.dig("methodDetails", "splits")
            raise Mpp::VerificationFailedError.new(reason: "EVM authorization credentials do not support splits")
          end

          unless addresses_equal?(payload["to"], request["recipient"])
            raise Mpp::VerificationFailedError.new(reason: "EVM authorization recipient mismatch")
          end
          unless payload["value"].to_s == request["amount"].to_s
            raise Mpp::VerificationFailedError.new(reason: "EVM authorization amount mismatch")
          end

          unless x402_credential?(credential)
            expected_nonce = Authorization.challenge_hash(credential.challenge)
            unless payload["nonce"].to_s.downcase == expected_nonce.downcase
              raise Mpp::VerificationFailedError.new(reason: "EVM authorization challenge hash mismatch")
            end
          end

          now = Time.now.to_i
          raise Mpp::VerificationFailedError.new(reason: "EVM authorization is not valid yet") if Integer(payload["validAfter"]) > now
          raise Mpp::VerificationFailedError.new(reason: "EVM authorization has expired") if Integer(payload["validBefore"]) <= now

          chain_id = request.dig("methodDetails", "chainId")
          raise Mpp::VerificationFailedError.new(reason: "EVM authorization requires chainId") if chain_id.nil?

          signer = Authorization.recover(
            authorization: @authorization,
            chain_id: chain_id,
            currency: request["currency"],
            payload: payload
          )
          unless signer && addresses_equal?(signer, payload["from"])
            raise Mpp::VerificationFailedError.new(reason: "EVM authorization signature mismatch")
          end

          checksummed_from = Authorization.checksum_address(payload["from"])
          source = "did:pkh:eip155:#{chain_id}:#{checksummed_from}"
          if credential.source && credential.source != source
            raise Mpp::VerificationFailedError.new(reason: "EVM authorization source mismatch")
          end

          settled = settle(payload, request)
          Mpp::Receipt.success(settled.fetch("transaction"), method: "evm")
        end

        def payment_requirements(request)
          Mpp::X402::Server.to_payment_requirements(
            request,
            authorization: @authorization,
            max_timeout_seconds: @max_timeout_seconds
          )
        end

        private

        def settle(payload, request)
          requirements = payment_requirements(request)
          payment_payload = {
            "accepted" => requirements,
            "payload" => {
              "authorization" => {
                "from" => payload["from"],
                "nonce" => payload["nonce"],
                "to" => payload["to"],
                "validAfter" => payload["validAfter"].to_s,
                "validBefore" => payload["validBefore"].to_s,
                "value" => payload["value"].to_s
              },
              "signature" => payload["signature"]
            },
            "x402Version" => Mpp::X402::VERSION
          }

          verified = @facilitator.verify(payment_payload, requirements)
          unless verified["isValid"]
            raise Mpp::VerificationFailedError.new(
              reason: verified["invalidMessage"] || verified["invalidReason"] || "EVM facilitator verify failed"
            )
          end

          settled = @facilitator.settle(payment_payload, requirements)
          unless settled["success"]
            raise Mpp::VerificationFailedError.new(
              reason: settled["errorMessage"] || settled["errorReason"] || "EVM facilitator settlement failed"
            )
          end

          settled
        end

        def x402_credential?(credential)
          credential.payload.is_a?(Hash) && credential.payload["_x402"] == true
        end

        def addresses_equal?(left, right)
          return false if left.nil? || right.nil?

          left.to_s.delete_prefix("0x").downcase == right.to_s.delete_prefix("0x").downcase
        end
      end
    end
  end
end
