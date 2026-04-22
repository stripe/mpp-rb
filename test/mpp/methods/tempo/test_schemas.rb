# frozen_string_literal: true

require "test_helper"

class TestSchemas < Minitest::Test
  def test_charge_request_from_hash
    request = Mpp::Methods::Tempo::Schemas::ChargeRequest.from_hash(
      "amount" => "1000000",
      "currency" => "0x20c0000000000000000000000000000000000000",
      "recipient" => "0x1234567890abcdef1234567890abcdef12345678"
    )

    assert_equal "1000000", request.amount
    assert_equal "0x20c0000000000000000000000000000000000000", request.currency
    assert_equal "0x1234567890abcdef1234567890abcdef12345678", request.recipient
    assert_equal 4217, request.method_details.chain_id
  end

  def test_charge_request_with_method_details
    request = Mpp::Methods::Tempo::Schemas::ChargeRequest.from_hash(
      "amount" => "1000000",
      "currency" => "0x20c0000000000000000000000000000000000000",
      "recipient" => "0x1234567890abcdef1234567890abcdef12345678",
      "methodDetails" => {"chainId" => 42_431, "feePayer" => true}
    )

    assert_equal 42_431, request.method_details.chain_id
    assert request.method_details.fee_payer
  end

  def test_charge_request_rejects_invalid_currency
    assert_raises(ArgumentError) do
      Mpp::Methods::Tempo::Schemas::ChargeRequest.from_hash(
        "amount" => "1000000",
        "currency" => "not-hex",
        "recipient" => "0x1234567890abcdef1234567890abcdef12345678"
      )
    end
  end

  def test_hash_credential_payload
    payload = Mpp::Methods::Tempo::Schemas::HashCredentialPayload.new(
      type: "hash",
      hash: "0xabc123"
    )

    assert_equal "hash", payload.type
    assert_equal "0xabc123", payload.hash
  end

  def test_transaction_credential_payload
    payload = Mpp::Methods::Tempo::Schemas::TransactionCredentialPayload.new(
      type: "transaction",
      signature: "0xdef456"
    )

    assert_equal "transaction", payload.type
    assert_equal "0xdef456", payload.signature
  end

  def test_parse_credential_payload_hash
    payload = Mpp::Methods::Tempo::Schemas.parse_credential_payload(
      "type" => "hash", "hash" => "0xabc"
    )

    assert_instance_of Mpp::Methods::Tempo::Schemas::HashCredentialPayload, payload
  end

  def test_parse_credential_payload_transaction
    payload = Mpp::Methods::Tempo::Schemas.parse_credential_payload(
      "type" => "transaction", "signature" => "0xdef"
    )

    assert_instance_of Mpp::Methods::Tempo::Schemas::TransactionCredentialPayload, payload
  end

  def test_proof_credential_payload
    payload = Mpp::Methods::Tempo::Schemas::ProofCredentialPayload.new(
      type: "proof",
      signature: "0xdef456"
    )

    assert_equal "proof", payload.type
    assert_equal "0xdef456", payload.signature
  end

  def test_parse_credential_payload_proof
    payload = Mpp::Methods::Tempo::Schemas.parse_credential_payload(
      "type" => "proof", "signature" => "0xabc"
    )

    assert_instance_of Mpp::Methods::Tempo::Schemas::ProofCredentialPayload, payload
  end

  def test_parse_credential_payload_invalid_type
    assert_raises(ArgumentError) do
      Mpp::Methods::Tempo::Schemas.parse_credential_payload("type" => "unknown")
    end
  end

  def test_method_details_defaults
    md = Mpp::Methods::Tempo::Schemas::MethodDetails.new

    assert_equal 4217, md.chain_id
    refute md.fee_payer
    assert_nil md.fee_payer_url
    assert_nil md.memo
  end
end
