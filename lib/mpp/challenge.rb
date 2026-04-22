# typed: true
# frozen_string_literal: true

require_relative "challenge_id"
require_relative "secure_compare"
require_relative "json"

module Mpp
  Challenge = Data.define(
    :id,
    :method,
    :intent,
    :request,
    :realm,
    :request_b64,
    :digest,
    :expires,
    :description,
    :opaque
  ) do
    def initialize(id:, method:, intent:, request:, realm: "", request_b64: "", digest: nil, expires: nil,
      description: nil, opaque: nil)
      super
    end

    # Create a Challenge with an HMAC-bound ID.
    def self.create(secret_key:, realm:, method:, intent:, request:, expires: nil, digest: nil, description: nil,
      meta: nil)
      challenge_id = Mpp.generate_challenge_id(
        secret_key: secret_key,
        realm: realm,
        method: method,
        intent: intent,
        request: request,
        expires: expires,
        digest: digest,
        opaque: meta
      )
      request_json = Mpp::Json.compact_encode(request)
      request_b64 = Mpp.b64url_encode(request_json)

      new(
        id: challenge_id,
        method: method,
        intent: intent,
        request: request,
        realm: realm,
        request_b64: request_b64,
        digest: digest,
        expires: expires,
        description: description,
        opaque: meta
      )
    end

    # Parse a Challenge from a WWW-Authenticate header value.
    def self.from_www_authenticate(header)
      Mpp::Parsing.parse_www_authenticate(header)
    end

    # Parse multiple Payment challenges from a merged WWW-Authenticate header.
    # Handles RFC 9110 §11.6.1 comma-separated authentication schemes.
    def self.from_www_authenticate_list(header)
      indices = []
      header.scan(/Payment\s+/i) { indices << T.must(Regexp.last_match).begin(0) }
      return [] if indices.empty?

      indices.each_with_index.map do |start_idx, i|
        end_idx = (i + 1 < indices.length) ? indices[i + 1] : header.length
        chunk = T.must(header[start_idx...end_idx]).sub(/,\s*$/, "")
        from_www_authenticate(chunk)
      end
    end

    # Serialize to a WWW-Authenticate header value.
    def to_www_authenticate(realm)
      Mpp::Parsing.format_www_authenticate(self, realm)
    end

    # Verify the challenge ID matches the expected HMAC.
    def verify(secret_key, realm)
      expected_id = Mpp.generate_challenge_id(
        secret_key: secret_key,
        realm: realm,
        method: method,
        intent: intent,
        request: request,
        expires: expires,
        digest: digest,
        opaque: opaque
      )
      Mpp.secure_compare(id, expected_id)
    end

    # Create a ChallengeEcho for use in credentials.
    def to_echo
      opaque_b64 = nil
      if opaque
        opaque_json = Mpp::Json.compact_encode(opaque)
        opaque_b64 = Mpp.b64url_encode(opaque_json)
      end

      ChallengeEcho.new(
        id: id,
        realm: realm,
        method: method,
        intent: intent,
        request: request_b64,
        expires: expires,
        digest: digest,
        opaque: opaque_b64
      )
    end
  end
end
