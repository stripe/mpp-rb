# typed: strict
# frozen_string_literal: true

require "openssl"
require "base64"
require "json"

module Mpp
  module BodyDigest
    extend T::Sig

    module_function

    # Compute a SHA-256 digest of a request body.
    # Returns: "sha-256=<base64>"
    sig { params(body: T.untyped).returns(String) }
    def compute(body)
      case body
      when Hash
        body = Mpp::Json.compact_encode(body)
      when String
        # use as-is
      end
      body = body.encode(Encoding::UTF_8) if body.is_a?(String)
      digest = OpenSSL::Digest::SHA256.digest(body)
      encoded = Base64.strict_encode64(digest)
      "sha-256=#{encoded}"
    end

    # Verify a body digest matches the expected value.
    sig { params(digest: String, body: T.untyped).returns(T::Boolean) }
    def verify(digest, body)
      expected = compute(body)
      Mpp.secure_compare(expected, digest)
    end
  end
end
