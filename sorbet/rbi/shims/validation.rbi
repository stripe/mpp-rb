# typed: strict

module Mpp
  class Validation
    sig { returns(Mpp::ChallengeEcho) }
    def challenge; end

    sig { returns(Mpp::Credential) }
    def credential; end

    sig { returns(T.untyped) }
    def details; end

    sig { returns(String) }
    def intent; end

    sig { returns(String) }
    def method; end

    sig { returns(T::Hash[String, T.untyped]) }
    def request; end

    sig { returns(T.nilable(String)) }
    def source; end
  end
end
