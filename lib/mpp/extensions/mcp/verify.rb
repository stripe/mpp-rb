# typed: strict
# frozen_string_literal: true

require "time"

module Mpp
  module Extensions
    module MCP
      extend T::Sig

      DEFAULT_CHALLENGE_TTL = T.let(5 * 60, Integer) # 5 minutes in seconds

      module_function

      # Verify a payment credential or generate a new challenge.
      # Returns MCPChallenge or [MCPCredential, MCPReceipt].
      sig { params(meta: T.untyped, intent: T.untyped, request: T.untyped, realm: String, secret_key: String, method: T.nilable(String), expires_in: Integer, description: T.nilable(String)).returns(T.untyped) }
      def verify_or_challenge(meta:, intent:, request:, realm:, secret_key:,
        method: nil, expires_in: DEFAULT_CHALLENGE_TTL, description: nil)
        method_name = method || "tempo"
        meta ||= {}

        new_challenge = Kernel.lambda {
          create_challenge(
            method: method_name,
            intent_name: intent.name,
            request: request,
            realm: realm,
            secret_key: secret_key,
            expires_in: expires_in,
            description: description
          )
        }

        credential_data = meta[META_CREDENTIAL]
        return new_challenge.call unless credential_data

        begin
          mcp_credential = MCPCredential.from_dict(credential_data)
        rescue KeyError, TypeError, NoMethodError => e
          Kernel.raise MalformedCredentialError.new(detail: "Invalid credential structure: #{e}")
        end

        # Stateless challenge verification
        echoed = mcp_credential.challenge
        expected_id = Mpp.generate_challenge_id(
          secret_key: secret_key,
          realm: echoed.realm,
          method: echoed.method,
          intent: echoed.intent,
          request: echoed.request,
          expires: echoed.expires,
          digest: echoed.digest,
          opaque: echoed.opaque
        )
        return new_challenge.call unless Mpp.secure_compare(echoed.id, expected_id)

        # Assert echoed fields match server's values
        unless echoed.realm == realm && echoed.method == method_name && echoed.intent == intent.name
          return new_challenge.call
        end

        # Assert echoed request matches server's current request
        return new_challenge.call unless echoed.request == request

        # Reject expired challenges as defense-in-depth
        if echoed.expires
          begin
            expires_dt = Time.iso8601(echoed.expires.gsub("Z", "+00:00"))
            return new_challenge.call if expires_dt < Time.now.utc
          rescue ArgumentError
            # continue to stricter check
          end
        end

        # Verify echoed request parameters
        echoed_request = echoed.request.is_a?(Hash) ? echoed.request : {}
        request.each do |key, value|
          next if key == "expires"

          return new_challenge.call unless echoed_request[key] == value
        end

        # Enforce challenge expiry - fail closed
        return new_challenge.call unless echoed.expires

        begin
          expires_dt = Time.iso8601(echoed.expires.gsub("Z", "+00:00"))
        rescue ArgumentError
          return new_challenge.call
        end
        return new_challenge.call if expires_dt < Time.now.utc

        core_credential = mcp_credential.to_core

        begin
          core_receipt = intent.verify(core_credential, request)
        rescue Mpp::VerificationError => e
          Kernel.raise PaymentVerificationError.new(
            challenges: [new_challenge.call],
            reason: "verification-failed",
            detail: e.message
          )
        end

        mcp_receipt = MCPReceipt.from_core(
          core_receipt,
          challenge_id: mcp_credential.challenge.id,
          method: mcp_credential.challenge.method,
          settlement: extract_settlement(request)
        )

        [mcp_credential, mcp_receipt]
      end

      sig { params(method: T.untyped, intent_name: T.untyped, request: T.untyped, realm: T.untyped, secret_key: T.untyped, expires_in: BasicObject, description: T.untyped).returns(Mpp::Extensions::MCP::MCPChallenge) }
      def create_challenge(method:, intent_name:, request:, realm:, secret_key:,
        expires_in: DEFAULT_CHALLENGE_TTL, description: nil)
        expires_time = Time.now.utc + expires_in
        expires = expires_time.iso8601
        expires = expires.sub(/\+00:00$/, "Z")

        challenge_id = Mpp.generate_challenge_id(
          secret_key: secret_key,
          realm: realm,
          method: method,
          intent: intent_name,
          request: request,
          expires: expires
        )

        MCPChallenge.new(
          id: challenge_id,
          realm: realm,
          method: method,
          intent: intent_name,
          request: request,
          expires: expires,
          description: description
        )
      end

      sig { params(request: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def extract_settlement(request)
        settlement = {}
        settlement["amount"] = request["amount"] if request.key?("amount")
        settlement["currency"] = request["currency"] if request.key?("currency")
        settlement.empty? ? nil : settlement
      end
    end
  end
end
