# frozen_string_literal: true

require "test_helper"

class TestMCPTypes < Minitest::Test
  def test_mcp_challenge_to_dict
    challenge = Mpp::Extensions::MCP::MCPChallenge.new(
      id: "ch_abc",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000"},
      expires: "2026-01-15T12:05:00Z",
      description: "API call fee"
    )
    dict = challenge.to_dict

    assert_equal "ch_abc", dict["id"]
    assert_equal "api.example.com", dict["realm"]
    assert_equal "tempo", dict["method"]
    assert_equal "charge", dict["intent"]
    assert_equal({"amount" => "1000"}, dict["request"])
    assert_equal "2026-01-15T12:05:00Z", dict["expires"]
    assert_equal "API call fee", dict["description"]
  end

  def test_mcp_challenge_from_dict
    data = {
      "id" => "ch_abc",
      "realm" => "api.example.com",
      "method" => "tempo",
      "intent" => "charge",
      "request" => {"amount" => "1000"}
    }
    challenge = Mpp::Extensions::MCP::MCPChallenge.from_dict(data)

    assert_equal "ch_abc", challenge.id
    assert_nil challenge.expires
  end

  def test_mcp_challenge_roundtrip
    original = Mpp::Extensions::MCP::MCPChallenge.new(
      id: "ch_abc",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000"},
      expires: "2026-01-15T12:05:00Z"
    )
    roundtripped = Mpp::Extensions::MCP::MCPChallenge.from_dict(original.to_dict)

    assert_equal original.id, roundtripped.id
    assert_equal original.realm, roundtripped.realm
    assert_equal original.request, roundtripped.request
    assert_equal original.expires, roundtripped.expires
  end

  def test_mcp_credential_to_dict
    challenge = Mpp::Extensions::MCP::MCPChallenge.new(
      id: "ch_abc", realm: "api.example.com", method: "tempo",
      intent: "charge", request: {"amount" => "1000"}
    )
    credential = Mpp::Extensions::MCP::MCPCredential.new(
      challenge: challenge,
      payload: {"type" => "transaction", "signature" => "0xabc"},
      source: "did:pkh:eip155:4217:0x1234"
    )
    dict = credential.to_dict

    assert dict.key?("challenge")
    assert dict.key?("payload")
    assert_equal "did:pkh:eip155:4217:0x1234", dict["source"]
  end

  def test_mcp_credential_to_meta
    challenge = Mpp::Extensions::MCP::MCPChallenge.new(
      id: "ch_abc", realm: "api.example.com", method: "tempo",
      intent: "charge", request: {"amount" => "1000"}
    )
    credential = Mpp::Extensions::MCP::MCPCredential.new(
      challenge: challenge, payload: {"type" => "hash", "hash" => "0xabc"}
    )
    meta = credential.to_meta

    assert meta.key?("org.paymentauth/credential")
  end

  def test_mcp_credential_from_meta
    challenge = Mpp::Extensions::MCP::MCPChallenge.new(
      id: "ch_abc", realm: "api.example.com", method: "tempo",
      intent: "charge", request: {"amount" => "1000"}
    )
    credential = Mpp::Extensions::MCP::MCPCredential.new(
      challenge: challenge, payload: {"type" => "hash", "hash" => "0xabc"}
    )
    meta = credential.to_meta
    parsed = Mpp::Extensions::MCP::MCPCredential.from_meta(meta)

    refute_nil parsed
    assert_equal "ch_abc", parsed.challenge.id
  end

  def test_mcp_credential_from_meta_missing
    assert_nil Mpp::Extensions::MCP::MCPCredential.from_meta({})
  end

  def test_mcp_credential_to_core
    challenge = Mpp::Extensions::MCP::MCPChallenge.new(
      id: "ch_abc", realm: "api.example.com", method: "tempo",
      intent: "charge", request: {"amount" => "1000"}
    )
    mcp_cred = Mpp::Extensions::MCP::MCPCredential.new(
      challenge: challenge,
      payload: {"type" => "transaction", "signature" => "0xabc"},
      source: "did:pkh:eip155:4217:0x1234"
    )
    core_cred = mcp_cred.to_core

    assert_instance_of Mpp::Credential, core_cred
    assert_equal "ch_abc", core_cred.challenge.id
    assert_equal "api.example.com", core_cred.challenge.realm
  end

  def test_mcp_receipt_to_dict
    receipt = Mpp::Extensions::MCP::MCPReceipt.new(
      status: "success",
      challenge_id: "ch_abc",
      method: "tempo",
      timestamp: "2026-01-15T12:00:30Z",
      reference: "0xtx789",
      settlement: {"amount" => "1000", "currency" => "0x1234"}
    )
    dict = receipt.to_dict

    assert_equal "success", dict["status"]
    assert_equal "ch_abc", dict["challengeId"]
    assert_equal "tempo", dict["method"]
    assert_equal "0xtx789", dict["reference"]
  end

  def test_mcp_receipt_to_meta
    receipt = Mpp::Extensions::MCP::MCPReceipt.new(
      status: "success", challenge_id: "ch_abc", method: "tempo",
      timestamp: "2026-01-15T12:00:30Z"
    )
    meta = receipt.to_meta

    assert meta.key?("org.paymentauth/receipt")
  end

  def test_mcp_receipt_from_core
    core_receipt = Mpp::Receipt.new(
      status: "success",
      timestamp: Time.utc(2026, 1, 15, 12, 0, 30),
      reference: "0xtx789",
      method: "tempo"
    )
    mcp_receipt = Mpp::Extensions::MCP::MCPReceipt.from_core(
      core_receipt,
      challenge_id: "ch_abc",
      method: "tempo",
      settlement: {"amount" => "1000"}
    )

    assert_equal "success", mcp_receipt.status
    assert_equal "ch_abc", mcp_receipt.challenge_id
    assert_equal "0xtx789", mcp_receipt.reference
    assert_equal({"amount" => "1000"}, mcp_receipt.settlement)
  end
end
