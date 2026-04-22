# frozen_string_literal: true

require "test_helper"

class TestMCPErrors < Minitest::Test
  def test_payment_required_error
    challenge = Mpp::Extensions::MCP::MCPChallenge.new(
      id: "ch_abc", realm: "api.example.com", method: "tempo",
      intent: "charge", request: {"amount" => "1000"}
    )
    error = Mpp::Extensions::MCP::PaymentRequiredError.new(challenges: [challenge])

    assert_equal "Payment Required", error.message
    assert_equal(-32_042, error.code)

    jsonrpc = error.to_jsonrpc_error

    assert_equal(-32_042, jsonrpc["code"])
    assert_equal "Payment Required", jsonrpc["message"]
    assert_equal 402, jsonrpc["data"]["httpStatus"]
    assert_equal 1, jsonrpc["data"]["challenges"].length
    assert_equal "ch_abc", jsonrpc["data"]["challenges"][0]["id"]
  end

  def test_payment_verification_error
    challenge = Mpp::Extensions::MCP::MCPChallenge.new(
      id: "ch_abc", realm: "api.example.com", method: "tempo",
      intent: "charge", request: {"amount" => "1000"}
    )
    error = Mpp::Extensions::MCP::PaymentVerificationError.new(
      challenges: [challenge],
      reason: "signature-invalid",
      detail: "Signature verification failed"
    )

    assert_equal(-32_043, error.code)

    jsonrpc = error.to_jsonrpc_error

    assert_equal(-32_043, jsonrpc["code"])
    assert_equal "signature-invalid", jsonrpc["data"]["failure"]["reason"]
    assert_equal "Signature verification failed", jsonrpc["data"]["failure"]["detail"]
  end

  def test_malformed_credential_error
    error = Mpp::Extensions::MCP::MalformedCredentialError.new(
      detail: "Missing required field: challenge.id"
    )

    assert_equal "Invalid params", error.message
    assert_equal(-32_602, error.code)

    jsonrpc = error.to_jsonrpc_error

    assert_equal(-32_602, jsonrpc["code"])
    assert_equal "Missing required field: challenge.id", jsonrpc["data"]["detail"]
    assert_equal 402, jsonrpc["data"]["httpStatus"]
  end

  def test_verification_error_without_failure
    challenge = Mpp::Extensions::MCP::MCPChallenge.new(
      id: "ch_abc", realm: "api.example.com", method: "tempo",
      intent: "charge", request: {}
    )
    error = Mpp::Extensions::MCP::PaymentVerificationError.new(challenges: [challenge])
    jsonrpc = error.to_jsonrpc_error

    refute jsonrpc["data"].key?("failure")
  end
end
