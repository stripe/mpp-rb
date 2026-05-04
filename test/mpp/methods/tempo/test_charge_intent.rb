# frozen_string_literal: true

require "test_helper"

class TestTempoChargeIntent < Minitest::Test
  CURRENCY = "0x20c0000000000000000000000000000000000000"
  HASH = "0xabc123"
  REALM = "api.example.com"
  RECIPIENT = "0x1234567890abcdef1234567890abcdef12345678"
  SENDER = "0x0000000000000000000000000000000000000001"

  def setup
    @intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test")
  end

  def test_hash_without_explicit_memo_accepts_challenge_bound_attribution_memo
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: "challenge-123"
    )

    receipt = receipt([transfer_log(memo: memo), transfer_log])

    result = verify_hash(receipt, challenge_id: "challenge-123")

    assert_equal HASH, result.reference
  end

  def test_hash_without_explicit_memo_rejects_plain_transfer
    error = assert_raises(Mpp::VerificationError) do
      verify_hash(receipt([transfer_log]), challenge_id: "challenge-123")
    end

    assert_match(/memo is not bound to this challenge/, error.message)
  end

  def test_hash_without_explicit_memo_rejects_wrong_challenge_nonce
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: "challenge-abc"
    )

    error = assert_raises(Mpp::VerificationError) do
      verify_hash(receipt([transfer_log(memo: memo), transfer_log]), challenge_id: "challenge-xyz")
    end

    assert_match(/memo is not bound to this challenge/, error.message)
  end

  def test_hash_without_explicit_memo_rejects_wrong_realm
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: "other.example.com",
      challenge_id: "challenge-123"
    )

    error = assert_raises(Mpp::VerificationError) do
      verify_hash(receipt([transfer_log(memo: memo), transfer_log]), challenge_id: "challenge-123")
    end

    assert_match(/memo is not bound to this challenge/, error.message)
  end

  def test_hash_with_explicit_memo_accepts_exact_memo
    explicit_memo = "0x#{"ab" * 32}"
    result = verify_hash(
      receipt([transfer_log(memo: explicit_memo)]),
      challenge_id: "challenge-123",
      memo: explicit_memo
    )

    assert_equal HASH, result.reference
  end

  private

  def verify_hash(receipt, challenge_id:, memo: nil)
    credential = Mpp::Credential.new(
      challenge: Mpp::ChallengeEcho.new(
        id: challenge_id,
        realm: REALM,
        method: "tempo",
        intent: "charge",
        request: ""
      ),
      payload: {"type" => "hash", "hash" => HASH}
    )

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, method, params) {
      assert_equal "eth_getTransactionReceipt", method
      assert_equal [HASH], params
      receipt
    }) do
      @intent.verify(credential, request_hash(memo: memo))
    end
  end

  def request_hash(memo: nil)
    request = {
      "amount" => "1000",
      "currency" => CURRENCY,
      "recipient" => RECIPIENT
    }
    request["methodDetails"] = {"memo" => memo} if memo
    request
  end

  def receipt(logs)
    {"status" => "0x1", "from" => SENDER, "logs" => logs}
  end

  def transfer_log(memo: nil)
    topics = [
      memo ? Mpp::Methods::Tempo::TRANSFER_WITH_MEMO_TOPIC : Mpp::Methods::Tempo::TRANSFER_TOPIC,
      topic_address(SENDER),
      topic_address(RECIPIENT)
    ]
    topics << memo if memo

    {
      "address" => CURRENCY,
      "topics" => topics,
      "data" => "0x#{1000.to_s(16).rjust(64, "0")}"
    }
  end

  def topic_address(address)
    "0x#{address.delete_prefix("0x").rjust(64, "0")}"
  end
end
