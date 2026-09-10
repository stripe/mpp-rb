# frozen_string_literal: true

require "test_helper"

class MCPMockIntent
  attr_reader :name

  def initialize(name: "charge")
    @name = name
  end

  def verify(_credential, _request)
    Mpp::Receipt.success("0xmocktxhash", method: "tempo")
  end
end

class TestMCPVerify < Minitest::Test
  SECRET = "test-mcp-secret"
  REALM = "api.example.com"

  def setup
    @intent = MCPMockIntent.new
  end

  def test_returns_challenge_when_no_meta
    result = Mpp::Extensions::MCP.verify_or_challenge(
      meta: nil,
      intent: @intent,
      request: {"amount" => "1000000"},
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Extensions::MCP::MCPChallenge, result
    assert_equal "tempo", result.method
    assert_equal "charge", result.intent
    assert_equal REALM, result.realm
  end

  def test_returns_challenge_when_no_credential_in_meta
    result = Mpp::Extensions::MCP.verify_or_challenge(
      meta: {},
      intent: @intent,
      request: {"amount" => "1000000"},
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Extensions::MCP::MCPChallenge, result
  end

  def test_challenge_has_expires
    result = Mpp::Extensions::MCP.verify_or_challenge(
      meta: nil,
      intent: @intent,
      request: {"amount" => "1000000"},
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Extensions::MCP::MCPChallenge, result
    refute_nil result.expires
  end

  def test_successful_verification
    request = {"amount" => "1000000"}
    challenge = Mpp::Extensions::MCP.create_challenge(
      method: "tempo",
      intent_name: "charge",
      request: request,
      realm: REALM,
      secret_key: SECRET
    )
    credential = Mpp::Extensions::MCP::MCPCredential.new(
      challenge: challenge,
      payload: {"type" => "transaction", "signature" => "0xabc"},
      source: "did:pkh:eip155:4217:0x1234"
    )
    meta = credential.to_meta

    result = Mpp::Extensions::MCP.verify_or_challenge(
      meta: meta,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Array, result
    cred, receipt = result

    assert_instance_of Mpp::Extensions::MCP::MCPCredential, cred
    assert_instance_of Mpp::Extensions::MCP::MCPReceipt, receipt
    assert_equal "success", receipt.status
    assert_equal challenge.id, receipt.challenge_id
  end

  def test_rejects_wrong_secret
    request = {"amount" => "1000000"}
    challenge = Mpp::Extensions::MCP.create_challenge(
      method: "tempo",
      intent_name: "charge",
      request: request,
      realm: REALM,
      secret_key: "different-secret"
    )
    credential = Mpp::Extensions::MCP::MCPCredential.new(
      challenge: challenge,
      payload: {"type" => "hash", "hash" => "0x123"}
    )
    meta = credential.to_meta

    result = Mpp::Extensions::MCP.verify_or_challenge(
      meta: meta,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Extensions::MCP::MCPChallenge, result
  end

  def test_rejects_mismatched_request
    request = {"amount" => "1000000"}
    challenge = Mpp::Extensions::MCP.create_challenge(
      method: "tempo",
      intent_name: "charge",
      request: {"amount" => "9999999"},
      realm: REALM,
      secret_key: SECRET
    )
    credential = Mpp::Extensions::MCP::MCPCredential.new(
      challenge: challenge,
      payload: {"type" => "hash", "hash" => "0x123"}
    )
    meta = credential.to_meta

    result = Mpp::Extensions::MCP.verify_or_challenge(
      meta: meta,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Extensions::MCP::MCPChallenge, result
  end

  def test_receipt_includes_settlement
    request = {"amount" => "1000000", "currency" => "0x1234"}
    challenge = Mpp::Extensions::MCP.create_challenge(
      method: "tempo",
      intent_name: "charge",
      request: request,
      realm: REALM,
      secret_key: SECRET
    )
    credential = Mpp::Extensions::MCP::MCPCredential.new(
      challenge: challenge,
      payload: {"type" => "transaction", "signature" => "0xabc"}
    )
    meta = credential.to_meta

    result = Mpp::Extensions::MCP.verify_or_challenge(
      meta: meta,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET
    )
    _cred, receipt = result

    assert_equal({"amount" => "1000000", "currency" => "0x1234"}, receipt.settlement)
  end
end

class TestMCPCreateChallenge < Minitest::Test
  def test_create_challenge
    challenge = Mpp::Extensions::MCP.create_challenge(
      method: "tempo",
      intent_name: "charge",
      request: {"amount" => "1000000"},
      realm: "api.example.com",
      secret_key: "test-secret"
    )

    assert_instance_of Mpp::Extensions::MCP::MCPChallenge, challenge
    assert_equal "tempo", challenge.method
    assert_equal "charge", challenge.intent
    refute_nil challenge.id
    refute_nil challenge.expires
  end

  def test_create_challenge_with_description
    challenge = Mpp::Extensions::MCP.create_challenge(
      method: "tempo",
      intent_name: "charge",
      request: {"amount" => "1000000"},
      realm: "api.example.com",
      secret_key: "test-secret",
      description: "API call fee"
    )

    assert_equal "API call fee", challenge.description
  end
end

class TestPaymentCapabilities < Minitest::Test
  def test_payment_capabilities
    caps = Mpp::Extensions::MCP.payment_capabilities(["tempo"], ["charge"])

    assert_equal({"methods" => ["tempo"], "intents" => ["charge"]}, caps["payment"])
  end
end
