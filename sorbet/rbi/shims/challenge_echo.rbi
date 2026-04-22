# typed: strict

module Mpp
  class ChallengeEcho
    sig { returns(String) }
    def id; end

    sig { returns(String) }
    def realm; end

    sig { returns(String) }
    def method; end

    sig { returns(String) }
    def intent; end

    sig { returns(String) }
    def request; end

    sig { returns(T.nilable(String)) }
    def expires; end

    sig { returns(T.nilable(String)) }
    def digest; end

    sig { returns(T.nilable(String)) }
    def opaque; end

  end
end
