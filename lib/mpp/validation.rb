# typed: true
# frozen_string_literal: true

module Mpp
  # Non-mutating validation result, matching mppx's Method.Validation fields.
  # Details are method-specific, not a receipt or a guarantee of settlement.
  # Challenge issuance and route binding are checked by the server, not by
  # constructing this record or calling a rail's validate method directly.
  Validation = Data.define(:challenge, :credential, :intent, :method, :request, :details, :source) do
    extend T::Sig

    sig do
      params(
        challenge: Mpp::ChallengeEcho,
        credential: Mpp::Credential,
        intent: String,
        method: String,
        request: T::Hash[String, T.untyped],
        details: T.untyped,
        source: T.nilable(String)
      ).void
    end
    def initialize(challenge:, credential:, intent:, method:, request:, details:, source: nil)
      super
    end
  end
end
