# typed: strict
# frozen_string_literal: true

require "base64"
require "json"
require "time"

module Mpp
  module Parsing
    extend T::Sig

    MAX_HEADER_PAYLOAD_SIZE = T.let(16 * 1024, Integer)

    # RFC 9110 auth-param regex: key="value" or key=token
    AUTH_PARAM_RE = /([a-zA-Z_][\w-]*)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s,]+))/

    module_function

    # Encode dict as URL-safe base64 JSON (compact, no padding).
    sig { params(data: T.untyped).returns(String) }
    def b64_encode(data)
      compact_json = Mpp::Json.compact_encode(data)
      Base64.urlsafe_encode64(compact_json, padding: false)
    end

    # Decode URL-safe base64 JSON to hash.
    sig { params(encoded: T.untyped).returns(T::Hash[T.untyped, T.untyped]) }
    def b64_decode(encoded)
      Kernel.raise Mpp::ParseError, "Header payload exceeds maximum size" if encoded.length > MAX_HEADER_PAYLOAD_SIZE

      padded = encoded + ("=" * ((-encoded.length) % 4))
      decoded = Base64.urlsafe_decode64(padded)
      obj = JSON.parse(decoded)
      Kernel.raise Mpp::ParseError, "Expected JSON object" unless obj.is_a?(Hash)

      obj
    rescue ArgumentError, JSON::ParserError
      Kernel.raise Mpp::ParseError, "Invalid base64 or JSON encoding"
    end

    # Escape a string for use in a quoted-string. Rejects CRLF.
    sig { params(str: String).returns(String) }
    def escape_quoted(str)
      Kernel.raise Mpp::ParseError, "Header value contains invalid CRLF characters" if str.include?("\r") || str.include?("\n")

      str.gsub("\\", "\\\\\\\\").gsub('"', '\\"')
    end

    # Unescape a quoted-string value.
    sig { params(str: String).returns(String) }
    def unescape_quoted(str)
      str.gsub(/\\(.)/, '\1')
    end

    # Parse RFC 9110 auth-params into a hash.
    sig { params(params_str: T.untyped).returns(T::Hash[T.untyped, T.untyped]) }
    def parse_auth_params(params_str)
      params = {}
      params_str.scan(AUTH_PARAM_RE) do |key, quoted_val, token_val|
        Kernel.raise Mpp::ParseError, "Duplicate parameter: #{key}" if params.key?(key)

        value = quoted_val.nil? ? token_val : unescape_quoted(quoted_val)
        params[key] = value
      end
      params
    end

    # Parse a WWW-Authenticate header into a Challenge.
    sig { params(header: T.untyped).returns(Mpp::Challenge) }
    def parse_www_authenticate(header)
      header = header.strip
      Kernel.raise Mpp::ParseError, "Expected 'Payment' authentication scheme" unless header.downcase.start_with?("payment ")

      params_str = header[8..].strip
      params = parse_auth_params(params_str)

      id = params["id"]
      Kernel.raise Mpp::ParseError, "Missing 'id' field" unless id && !id.empty?

      realm = params["realm"]
      Kernel.raise Mpp::ParseError, "Missing 'realm' field" unless realm && !realm.empty?

      method = params["method"]
      Kernel.raise Mpp::ParseError, "Missing 'method' field" unless method && !method.empty?

      intent = params["intent"]
      Kernel.raise Mpp::ParseError, "Missing 'intent' field" unless intent && !intent.empty?

      request_b64 = params["request"]
      Kernel.raise Mpp::ParseError, "Missing 'request' field" unless request_b64 && !request_b64.empty?

      request = b64_decode(request_b64)

      opaque_b64 = params["opaque"]
      opaque = (opaque_b64 && !opaque_b64.empty?) ? b64_decode(opaque_b64) : nil

      Mpp::Challenge.new(
        id: id,
        method: method,
        intent: intent,
        request: request,
        realm: realm,
        request_b64: request_b64,
        digest: params["digest"],
        expires: params["expires"],
        description: params["description"],
        opaque: opaque
      )
    end

    # Format a Challenge as a WWW-Authenticate header value.
    sig { params(challenge: T.untyped, realm: T.untyped).returns(String) }
    def format_www_authenticate(challenge, realm)
      request_b64 = b64_encode(challenge.request)

      parts = [
        "id=\"#{escape_quoted(challenge.id)}\"",
        "realm=\"#{escape_quoted(realm)}\"",
        "method=\"#{escape_quoted(challenge.method)}\"",
        "intent=\"#{escape_quoted(challenge.intent)}\"",
        "request=\"#{request_b64}\""
      ]

      parts << "digest=\"#{escape_quoted(challenge.digest)}\"" if challenge.digest
      parts << "expires=\"#{escape_quoted(challenge.expires)}\"" if challenge.expires
      parts << "description=\"#{escape_quoted(challenge.description)}\"" if challenge.description
      if challenge.opaque
        opaque_b64 = b64_encode(challenge.opaque)
        parts << "opaque=\"#{opaque_b64}\""
      end

      "Payment #{parts.join(", ")}"
    end

    # Parse an Authorization header into a Credential.
    sig { params(header: T.untyped).returns(Mpp::Credential) }
    def parse_authorization(header)
      header = header.strip
      Kernel.raise Mpp::ParseError, "Expected 'Payment' authentication scheme" unless header.downcase.start_with?("payment ")

      credential_b64 = header[8..].strip
      data = b64_decode(credential_b64)

      Kernel.raise Mpp::ParseError, "Credential missing required field: challenge" unless data.key?("challenge")
      Kernel.raise Mpp::ParseError, "Credential missing required field: payload" unless data.key?("payload")

      challenge_data = data["challenge"]
      Kernel.raise Mpp::ParseError, "Credential challenge must be an object" unless challenge_data.is_a?(Hash)
      Kernel.raise Mpp::ParseError, "Credential challenge missing required field: id" unless challenge_data.key?("id")

      echo = Mpp::ChallengeEcho.new(
        id: challenge_data["id"].to_s,
        realm: (challenge_data["realm"] || "").to_s,
        method: (challenge_data["method"] || "").to_s,
        intent: (challenge_data["intent"] || "").to_s,
        request: (challenge_data["request"] || "").to_s,
        expires: challenge_data["expires"]&.to_s,
        digest: challenge_data["digest"]&.to_s,
        opaque: challenge_data["opaque"]&.to_s
      )

      Mpp::Credential.new(
        challenge: echo,
        payload: data["payload"],
        source: data["source"]&.to_s
      )
    end

    # Format a Credential as an Authorization header value.
    sig { params(credential: T.untyped).returns(String) }
    def format_authorization(credential)
      challenge_dict = {
        "id" => credential.challenge.id,
        "realm" => credential.challenge.realm,
        "method" => credential.challenge.method,
        "intent" => credential.challenge.intent,
        "request" => credential.challenge.request
      }
      challenge_dict["expires"] = credential.challenge.expires if credential.challenge.expires
      challenge_dict["digest"] = credential.challenge.digest if credential.challenge.digest
      challenge_dict["opaque"] = credential.challenge.opaque if credential.challenge.opaque

      payload = {
        "challenge" => challenge_dict,
        "payload" => credential.payload
      }
      payload["source"] = credential.source if credential.source

      encoded = b64_encode(payload)
      "Payment #{encoded}"
    end

    # Parse an ISO 8601 timestamp string to Time.
    sig { params(value: T.untyped).returns(Time) }
    def parse_timestamp(value)
      ts_str = value.gsub("Z", "+00:00")
      Time.iso8601(ts_str)
    rescue ArgumentError
      Kernel.raise Mpp::ParseError, "Invalid timestamp format"
    end

    # Parse a Payment-Receipt header into a Receipt.
    sig { params(header: T.untyped).returns(Mpp::Receipt) }
    def parse_payment_receipt(header)
      header = header.strip
      data = b64_decode(header)

      required = %w[status timestamp reference method]
      missing = required - data.keys
      Kernel.raise Mpp::ParseError, "Receipt missing required fields: #{missing}" unless missing.empty?

      status = data["status"]
      Kernel.raise Mpp::ParseError, "Invalid receipt status" unless status == "success"

      timestamp = parse_timestamp(data["timestamp"].to_s)

      extra = data["extra"]
      extra = nil unless extra.is_a?(Hash)

      Mpp::Receipt.new(
        status: status,
        timestamp: timestamp,
        reference: data["reference"].to_s,
        method: (data["method"] || "").to_s,
        external_id: data["externalId"]&.to_s,
        extra: extra
      )
    end

    # Format a Receipt as a Payment-Receipt header value.
    sig { params(receipt: Mpp::Receipt).returns(String) }
    def format_payment_receipt(receipt)
      t = receipt.timestamp.utc
      timestamp_str = if t.usec == 0
        t.strftime("%Y-%m-%dT%H:%M:%SZ")
      else
        t.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
      end

      payload = {
        "method" => receipt.method,
        "reference" => receipt.reference,
        "status" => receipt.status,
        "timestamp" => timestamp_str
      }
      payload["externalId"] = receipt.external_id if receipt.external_id
      payload["extra"] = receipt.extra if receipt.extra

      b64_encode(payload)
    end
  end
end
