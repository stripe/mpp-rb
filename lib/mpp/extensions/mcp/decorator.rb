# typed: strict
# frozen_string_literal: true

module Mpp
  module Extensions
    module MCP
      extend T::Sig

      module_function

      # Wrapper for MCP tool handlers with payment verification.
      #
      # Usage:
      #   result = Mpp::Extensions::MCP.pay(mpp_handler, meta: params["_meta"],
      #     request: { "amount" => "1000" }, realm: "api.example.com") do |credential, receipt|
      #     # execute tool
      #   end
      sig { params(intent: T.untyped, request: T.untyped, meta: T.untyped, realm: T.nilable(String), secret_key: T.nilable(String), method: T.nilable(String), expires_in: Integer, description: T.nilable(String), blk: T.untyped).returns(T.untyped) }
      def pay_tool(intent:, request:, meta:, realm: nil, secret_key: nil,
        method: nil, expires_in: DEFAULT_CHALLENGE_TTL, description: nil, &blk)
        resolved_realm = realm || Mpp::Server::Defaults.detect_realm
        resolved_secret_key = secret_key || Mpp::Server::Defaults.detect_secret_key

        request_params = request.respond_to?(:call) ? request.call : request

        result = verify_or_challenge(
          meta: meta,
          intent: intent,
          request: request_params,
          realm: resolved_realm,
          secret_key: resolved_secret_key,
          method: method,
          expires_in: expires_in,
          description: description
        )

        Kernel.raise PaymentRequiredError.new(challenges: [result]) if result.is_a?(MCPChallenge)

        credential, receipt = result
        yield credential, receipt
      end
    end
  end
end
