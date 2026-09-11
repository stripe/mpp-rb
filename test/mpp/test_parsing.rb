# frozen_string_literal: true

require "test_helper"

class TestParsing < Minitest::Test
  def test_parse_www_authenticate_basic
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"}
    )
    header = challenge.to_www_authenticate("api.example.com")
    parsed = Mpp::Challenge.from_www_authenticate(header)

    assert_equal challenge.id, parsed.id
    assert_equal "api.example.com", parsed.realm
    assert_equal "tempo", parsed.method
    assert_equal "charge", parsed.intent
    assert_equal({"amount" => "1000000"}, parsed.request)
  end

  def test_parse_www_authenticate_with_optional_fields
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: "2026-01-29T12:00:00Z",
      description: "Test payment",
      digest: "sha-256=abc123"
    )
    header = challenge.to_www_authenticate("api.example.com")
    parsed = Mpp::Challenge.from_www_authenticate(header)

    assert_equal challenge.id, parsed.id
    assert_equal "sha-256=abc123", parsed.digest
    assert_equal "2026-01-29T12:00:00Z", parsed.expires
    assert_equal "Test payment", parsed.description
  end

  def test_www_authenticate_roundtrip
    challenge = Mpp::Challenge.create(
      secret_key: "roundtrip-secret",
      realm: "test.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "5000000", "currency" => "0x1234"},
      expires: "2026-06-01T00:00:00Z"
    )
    header = challenge.to_www_authenticate("test.example.com")
    parsed = Mpp::Challenge.from_www_authenticate(header)

    assert_equal challenge.id, parsed.id
    assert_equal challenge.request, parsed.request
    assert_equal challenge.expires, parsed.expires
    assert parsed.verify("roundtrip-secret", "test.example.com")
  end

  def test_parse_www_authenticate_rejects_non_payment
    assert_raises(Mpp::ParseError) { Mpp::Challenge.from_www_authenticate("Bearer token123") }
  end

  def test_parse_www_authenticate_rejects_missing_fields
    assert_raises(Mpp::ParseError) { Mpp::Challenge.from_www_authenticate('Payment id="abc"') }
  end

  def test_parse_www_authenticate_rejects_invalid_method_ids
    request_b64 = Mpp::Parsing.b64_encode({"amount" => "1000000"})

    invalid_payment_method_ids.each do |payment_method|
      header = %(Payment id="abc", realm="api.example.com", method="#{payment_method}", intent="charge", request="#{request_b64}")

      assert_raises(Mpp::ParseError) { Mpp::Challenge.from_www_authenticate(header) }
    end
  end

  def test_credential_roundtrip
    echo = Mpp::ChallengeEcho.new(
      id: "test-id",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: "eyJhbW91bnQiOiIxMDAwMDAwIn0"
    )
    credential = Mpp::Credential.new(
      challenge: echo,
      payload: {"type" => "transaction", "signature" => "0xabc"},
      source: "did:pkh:eip155:4217:0x1234"
    )
    header = credential.to_authorization
    parsed = Mpp::Credential.from_authorization(header)

    assert_equal "test-id", parsed.challenge.id
    assert_equal "api.example.com", parsed.challenge.realm
    assert_equal "tempo", parsed.challenge.method
    assert_equal "charge", parsed.challenge.intent
    assert_equal "transaction", parsed.payload["type"]
    assert_equal "0xabc", parsed.payload["signature"]
    assert_equal "did:pkh:eip155:4217:0x1234", parsed.source
  end

  def test_credential_without_source
    echo = Mpp::ChallengeEcho.new(
      id: "test-id",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: "eyJhbW91bnQiOiIxMDAwMDAwIn0"
    )
    credential = Mpp::Credential.new(
      challenge: echo,
      payload: {"type" => "hash", "hash" => "0xdef"}
    )
    header = credential.to_authorization
    parsed = Mpp::Credential.from_authorization(header)

    assert_nil parsed.source
    assert_equal "hash", parsed.payload["type"]
  end

  def test_parse_authorization_rejects_non_payment
    assert_raises(Mpp::ParseError) { Mpp::Credential.from_authorization("Bearer token123") }
  end

  def test_parse_authorization_rejects_invalid_challenge_method_ids
    invalid_payment_method_ids.each do |payment_method|
      payload = {
        "challenge" => {
          "id" => "test-id",
          "realm" => "api.example.com",
          "method" => payment_method,
          "intent" => "charge",
          "request" => "e30"
        },
        "payload" => {"type" => "hash", "hash" => "0xabc"}
      }
      header = "Payment #{Mpp::Parsing.b64_encode(payload)}"

      assert_raises(Mpp::ParseError) { Mpp::Credential.from_authorization(header) }
    end
  end

  def test_parse_authorization_rejects_non_string_challenge_method_ids
    non_string_payment_method_ids.each do |payment_method|
      payload = {
        "challenge" => {
          "id" => "test-id",
          "realm" => "api.example.com",
          "method" => payment_method,
          "intent" => "charge",
          "request" => "e30"
        },
        "payload" => {"type" => "hash", "hash" => "0xabc"}
      }
      header = "Payment #{Mpp::Parsing.b64_encode(payload)}"

      assert_raises(Mpp::ParseError) { Mpp::Credential.from_authorization(header) }
    end
  end

  def test_receipt_roundtrip
    receipt = Mpp::Receipt.new(
      status: "success",
      timestamp: Time.utc(2026, 1, 15, 12, 0, 30),
      reference: "0xabc123",
      method: "tempo"
    )
    header = receipt.to_payment_receipt
    parsed = Mpp::Receipt.from_payment_receipt(header)

    assert_equal "success", parsed.status
    assert_equal "0xabc123", parsed.reference
    assert_equal "tempo", parsed.method
    assert_nil parsed.subscription_id
    assert_equal 2026, parsed.timestamp.year
    assert_equal 1, parsed.timestamp.month
    assert_equal 15, parsed.timestamp.day
  end

  def test_receipt_with_external_id
    receipt = Mpp::Receipt.new(
      status: "success",
      timestamp: Time.utc(2026, 1, 15, 12, 0, 30),
      reference: "0xabc123",
      method: "tempo",
      external_id: "order-456"
    )
    header = receipt.to_payment_receipt
    parsed = Mpp::Receipt.from_payment_receipt(header)

    assert_equal "order-456", parsed.external_id
  end

  def test_receipt_with_subscription_id
    receipt = Mpp::Receipt.new(
      status: "success",
      timestamp: Time.utc(2026, 1, 15, 12, 0, 30),
      reference: "0xabc123",
      method: "tempo",
      subscription_id: "sub_123"
    )

    encoded = receipt.to_payment_receipt
    payload = Mpp::Parsing.b64_decode(encoded)
    parsed = Mpp::Receipt.from_payment_receipt(encoded)

    assert_equal "sub_123", payload["subscriptionId"]
    assert_equal "sub_123", parsed.subscription_id
  end

  def test_foreign_subscription_receipt_roundtrip
    encoded = Mpp::Parsing.b64_encode(
      "status" => "success",
      "timestamp" => "2026-01-15T12:00:30Z",
      "reference" => "0xabc123",
      "method" => "tempo",
      "subscriptionId" => "sub_foreign"
    )

    parsed = Mpp::Receipt.from_payment_receipt(encoded)
    roundtrip = Mpp::Parsing.b64_decode(parsed.to_payment_receipt)

    assert_equal "sub_foreign", parsed.subscription_id
    assert_equal "sub_foreign", roundtrip["subscriptionId"]
  end

  def test_receipt_success_factory
    receipt = Mpp::Receipt.success("0xdeadbeef")

    assert_equal "success", receipt.status
    assert_equal "0xdeadbeef", receipt.reference
    assert_equal "tempo", receipt.method
    assert_instance_of Time, receipt.timestamp
  end

  def test_receipt_success_factory_preserves_extra
    receipt = Mpp::Receipt.success(
      "0xdeadbeef",
      extra: {"trace_id" => "trace-123"}
    )

    assert_equal({"trace_id" => "trace-123"}, receipt.extra)
  end

  def test_receipt_success_factory_preserves_subscription_id
    receipt = Mpp::Receipt.success(
      "0xdeadbeef",
      subscription_id: "sub_123"
    )

    assert_equal "sub_123", receipt.subscription_id
  end

  def test_parse_payment_receipt_rejects_invalid_method_ids
    invalid_payment_method_ids.each do |payment_method|
      payload = {
        "status" => "success",
        "timestamp" => "2026-01-15T12:00:30Z",
        "reference" => "0xabc123",
        "method" => payment_method
      }
      header = Mpp::Parsing.b64_encode(payload)

      assert_raises(Mpp::ParseError) { Mpp::Receipt.from_payment_receipt(header) }
    end
  end

  def test_parse_payment_receipt_rejects_non_string_method_ids
    non_string_payment_method_ids.each do |payment_method|
      payload = {
        "status" => "success",
        "timestamp" => "2026-01-15T12:00:30Z",
        "reference" => "0xabc123",
        "method" => payment_method
      }
      header = Mpp::Parsing.b64_encode(payload)

      assert_raises(Mpp::ParseError) { Mpp::Receipt.from_payment_receipt(header) }
    end
  end

  def test_parse_payment_receipt_preserves_method_extension_fields
    encoded = Mpp::Parsing.b64_encode(
      "status" => "success",
      "timestamp" => "2026-01-15T12:00:30Z",
      "reference" => "0xabc123",
      "method" => "tempo",
      "originTxHash" => "0xdeadbeef"
    )

    parsed = Mpp::Receipt.from_payment_receipt(encoded)

    # Unknown top-level fields are captured in extensions, not dropped.
    assert_equal "0xdeadbeef", parsed.extensions["originTxHash"]

    # They are not smuggled into extra.
    assert_nil parsed.extra

    # Known base fields never leak into extensions.
    refute parsed.extensions.key?("reference")

    # Re-emitted at the top level on format, not nested under "extra".
    formatted = Mpp::Parsing.b64_decode(parsed.to_payment_receipt)
    assert_equal "0xdeadbeef", formatted["originTxHash"]
    refute formatted.key?("extra")

    # A full parse -> format -> parse round trip preserves it unchanged.
    reparsed = Mpp::Receipt.from_payment_receipt(parsed.to_payment_receipt)
    assert_equal "0xdeadbeef", reparsed.extensions["originTxHash"]
  end

  def test_challenge_to_echo
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"}
    )
    echo = challenge.to_echo

    assert_equal challenge.id, echo.id
    assert_equal "api.example.com", echo.realm
    assert_equal "tempo", echo.method
    assert_equal "charge", echo.intent
    assert_equal challenge.request_b64, echo.request
  end

  def test_www_authenticate_roundtrip_preserves_credential_header
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      header: Mpp::PAYMENT_AUTHORIZATION_HEADER
    )
    header = challenge.to_www_authenticate("api.example.com")
    parsed = Mpp::Challenge.from_www_authenticate(header)

    assert_includes header, %(header="#{Mpp::PAYMENT_AUTHORIZATION_HEADER}")
    assert_equal Mpp::PAYMENT_AUTHORIZATION_HEADER, parsed.header
    assert_equal Mpp::PAYMENT_AUTHORIZATION_HEADER, parsed.credential_header
    assert parsed.verify("test-secret", "api.example.com")
  end

  def test_www_authenticate_omits_default_authorization_header
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      header: "authorization"
    )
    header = challenge.to_www_authenticate("api.example.com")

    refute_includes header, "header="
    assert_nil challenge.header
  end

  def test_credential_roundtrip_preserves_header
    echo = Mpp::ChallengeEcho.new(
      id: "test-id",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: "eyJhbW91bnQiOiIxMDAwMDAwIn0",
      header: Mpp::PAYMENT_AUTHORIZATION_HEADER
    )
    credential = Mpp::Credential.new(
      challenge: echo,
      payload: {"type" => "transaction", "signature" => "0xabc"}
    )
    parsed = Mpp::Credential.from_authorization(credential.to_authorization)

    assert_equal Mpp::PAYMENT_AUTHORIZATION_HEADER, parsed.challenge.header
  end

  def test_parse_www_authenticate_rejects_invalid_header_name
    request_b64 = Mpp::Parsing.b64_encode({"amount" => "1000000"})
    header = %(Payment id="abc", realm="api.example.com", method="tempo", intent="charge", request="#{request_b64}", header="not a header")

    assert_raises(Mpp::ParseError) { Mpp::Challenge.from_www_authenticate(header) }
  end

  def test_base64url_empty_request
    # Empty JSON object {} encodes to "e30"
    encoded = Mpp::Parsing.b64_encode({})

    assert_equal "e30", encoded
  end

  def test_quoted_string_escaping
    escaped = Mpp::Parsing.escape_quoted('hello "world" and \\backslash')

    assert_includes escaped, '\\"'
    assert_includes escaped, "\\\\"
  end

  def test_opaque_roundtrip_through_headers
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      meta: {"pi" => "pi_3abc123"}
    )
    header = challenge.to_www_authenticate("api.example.com")
    parsed = Mpp::Challenge.from_www_authenticate(header)

    assert_equal({"pi" => "pi_3abc123"}, parsed.opaque)
    assert parsed.verify("test-secret", "api.example.com")
  end

  def test_from_www_authenticate_list_single
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"}
    )
    header = challenge.to_www_authenticate("api.example.com")
    result = Mpp::Challenge.from_www_authenticate_list(header)

    assert_equal 1, result.length
    assert_equal challenge.id, result[0].id
  end

  def test_from_www_authenticate_list_leading_whitespace
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"}
    )
    # A header carrying leading optional whitespace (RFC 9110 OWS) must still
    # surface the Payment challenge; the first scheme is a boundary even when
    # whitespace precedes it.
    header = "   #{challenge.to_www_authenticate("api.example.com")}"
    result = Mpp::Challenge.from_www_authenticate_list(header)

    assert_equal 1, result.length
    assert_equal challenge.id, result[0].id
  end

  def test_from_www_authenticate_list_multiple
    c1 = Mpp::Challenge.create(
      secret_key: "s1",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "100"}
    )
    c2 = Mpp::Challenge.create(
      secret_key: "s2",
      realm: "api.example.com",
      method: "other",
      intent: "charge",
      request: {"amount" => "200"}
    )
    header = "#{c1.to_www_authenticate("api.example.com")}, #{c2.to_www_authenticate("api.example.com")}"
    result = Mpp::Challenge.from_www_authenticate_list(header)

    assert_equal 2, result.length
    assert_equal "tempo", result[0].method
    assert_equal "other", result[1].method
  end

  def test_from_www_authenticate_list_ignores_payment_scheme_inside_quotes
    c1 = Mpp::Challenge.create(
      secret_key: "s1",
      realm: "api, Payment realm",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "100"}
    )
    c2 = Mpp::Challenge.create(
      secret_key: "s2",
      realm: "api.example.com",
      method: "stripe",
      intent: "charge",
      request: {"amount" => "200"}
    )
    header = "#{c1.to_www_authenticate("api, Payment realm")}, #{c2.to_www_authenticate("api.example.com")}"
    result = Mpp::Challenge.from_www_authenticate_list(header)

    assert_equal 2, result.length
    assert_equal "api, Payment realm", result[0].realm
    assert_equal "tempo", result[0].method
    assert_equal "stripe", result[1].method
  end

  def test_from_www_authenticate_list_stops_before_next_non_payment_scheme
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"}
    )
    header = "#{challenge.to_www_authenticate("api.example.com")}, Bearer realm=\"fallback\""
    result = Mpp::Challenge.from_www_authenticate_list(header)

    assert_equal 1, result.length
    assert_equal challenge.id, result[0].id
  end

  def test_from_www_authenticate_list_allows_whitespace_around_param_equals
    header = 'Payment id="ch", realm = "api", method="tempo", intent="charge", request="e30"'
    result = Mpp::Challenge.from_www_authenticate_list(header)

    # OWS around "=" (key\s*=\s*value) must not be mistaken for a new scheme
    # after a comma, so the challenge stays whole instead of truncating at realm.
    assert_equal 1, result.length
    assert_equal "tempo", result[0].method
  end

  def test_from_www_authenticate_list_ignores_interleaved_non_payment_scheme
    first = Mpp::Challenge.create(secret_key: "s", realm: "api.example.com", method: "tempo",
      intent: "charge", request: {"amount" => "1"})
    second = Mpp::Challenge.create(secret_key: "s", realm: "api.example.com", method: "tempo",
      intent: "charge", request: {"amount" => "2"})
    header = [
      first.to_www_authenticate("api.example.com"),
      'Bearer realm="fallback"',
      second.to_www_authenticate("api.example.com")
    ].join(", ")

    result = Mpp::Challenge.from_www_authenticate_list(header)

    # The interleaved Bearer scheme must terminate the first chunk rather than
    # folding into it (which would surface as a duplicate realm parse error).
    assert_equal 2, result.length
    assert_equal first.id, result[0].id
    assert_equal second.id, result[1].id
  end

  def test_from_www_authenticate_list_empty
    assert_equal [], Mpp::Challenge.from_www_authenticate_list("Bearer token123")
    assert_equal [], Mpp::Challenge.from_www_authenticate_list("")
  end

  private

  def invalid_payment_method_ids
    ["Tempo", "tempo2", "tempo-pay", "tempo_pay", "tempo.pay"]
  end

  def non_string_payment_method_ids
    [true, false]
  end
end
