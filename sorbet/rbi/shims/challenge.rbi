# typed: strict

module Mpp
  class Challenge
    sig { returns(String) }
    def id; end

    sig { returns(String) }
    def method; end

    sig { returns(String) }
    def intent; end

    sig { returns(T::Hash[String, T.untyped]) }
    def request; end

    sig { returns(String) }
    def realm; end

    sig { returns(String) }
    def request_b64; end

    sig { returns(T.nilable(String)) }
    def digest; end

    sig { returns(T.nilable(String)) }
    def expires; end

    sig { returns(T.nilable(String)) }
    def description; end

    sig { returns(T.nilable(T::Hash[String, T.untyped])) }
    def opaque; end

    sig do
      params(
        id: String,
        method: String,
        intent: String,
        request: T::Hash[String, T.untyped],
        realm: String,
        request_b64: String,
        digest: T.nilable(String),
        expires: T.nilable(String),
        description: T.nilable(String),
        opaque: T.nilable(T::Hash[String, T.untyped])
      ).void
    end
    def initialize(id:, method:, intent:, request:, realm: "", request_b64: "", digest: nil, expires: nil, description: nil, opaque: nil); end

    sig do
      params(
        secret_key: String,
        realm: String,
        method: String,
        intent: String,
        request: T::Hash[String, T.untyped],
        expires: T.nilable(String),
        digest: T.nilable(String),
        description: T.nilable(String),
        meta: T.nilable(T::Hash[String, T.untyped])
      ).returns(Challenge)
    end
    def self.create(secret_key:, realm:, method:, intent:, request:, expires: nil, digest: nil, description: nil, meta: nil); end

    sig { params(header: String).returns(Challenge) }
    def self.from_www_authenticate(header); end

    sig { params(header: String).returns(T::Array[Challenge]) }
    def self.from_www_authenticate_list(header); end

    sig { params(realm: String).returns(String) }
    def to_www_authenticate(realm); end

    sig { params(secret_key: String, realm: String).returns(T::Boolean) }
    def verify(secret_key, realm); end

    sig { returns(ChallengeEcho) }
    def to_echo; end
  end
end
