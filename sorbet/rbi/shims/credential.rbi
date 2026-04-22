# typed: strict

module Mpp
  class Credential
    sig { returns(ChallengeEcho) }
    def challenge; end

    sig { returns(T::Hash[String, T.untyped]) }
    def payload; end

    sig { returns(T.nilable(String)) }
    def source; end

    sig do
      params(
        challenge: ChallengeEcho,
        payload: T::Hash[String, T.untyped],
        source: T.nilable(String)
      ).void
    end
    def initialize(challenge:, payload:, source: nil); end

    sig { params(header: String).returns(Credential) }
    def self.from_authorization(header); end

    sig { returns(String) }
    def to_authorization; end
  end
end
