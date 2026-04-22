# typed: strict
# frozen_string_literal: true

require "openssl"
require "base64"

module Mpp
  extend T::Sig

  module_function

  # Generate HMAC-SHA256 challenge ID per spec.
  #
  # HMAC input format: realm|method|intent|request_b64|expires|digest|opaque_b64
  # All fields always included; absent optional fields use empty string.
  # Output: base64url(HMAC-SHA256(secret_key, input))
  sig { params(secret_key: T.untyped, realm: T.untyped, method: T.untyped, intent: T.untyped, request: T.untyped, expires: T.untyped, digest: T.untyped, opaque: T.untyped).returns(String) }
  def generate_challenge_id(secret_key:, realm:, method:, intent:, request:, expires: nil, digest: nil, opaque: nil)
    request_json = Json.compact_encode(request)
    request_b64 = b64url_encode(request_json)

    opaque_b64 = if opaque
      opaque_json = Json.compact_encode(opaque)
      b64url_encode(opaque_json)
    else
      ""
    end

    hmac_input = [
      realm,
      method,
      intent,
      request_b64,
      expires || "",
      digest || "",
      opaque_b64
    ].join("|")

    mac = OpenSSL::HMAC.digest("SHA256", secret_key.encode(Encoding::UTF_8), hmac_input.encode(Encoding::UTF_8))
    Base64.urlsafe_encode64(mac, padding: false)
  end

  # Encode string to base64url without padding.
  sig { params(data: T.untyped).returns(String) }
  def b64url_encode(data)
    Base64.urlsafe_encode64(data.encode(Encoding::UTF_8), padding: false)
  end

  # Encode bytes to base64url without padding.
  sig { params(data: String).returns(String) }
  def b64url_encode_bytes(data)
    Base64.urlsafe_encode64(data, padding: false)
  end
end
