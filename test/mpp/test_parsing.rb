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

  def test_receipt_success_factory
    receipt = Mpp::Receipt.success("0xdeadbeef")

    assert_equal "success", receipt.status
    assert_equal "0xdeadbeef", receipt.reference
    assert_equal "tempo", receipt.method
    assert_instance_of Time, receipt.timestamp
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

  def test_from_www_authenticate_list_empty
    assert_equal [], Mpp::Challenge.from_www_authenticate_list("Bearer token123")
    assert_equal [], Mpp::Challenge.from_www_authenticate_list("")
  end
end
