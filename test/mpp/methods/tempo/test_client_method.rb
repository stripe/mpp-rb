# typed: ignore
# frozen_string_literal: true

require "test_helper"

class TestTempoExpectedRecipients < Minitest::Test
  ALLOWED = "0x0000000000000000000000000000000000000001" # same as examples/
  OTHER = "0xabcd"

  def make_method(expected_recipients:)
    Mpp::Methods::Tempo::TempoMethod.new(
      account: stub_account,
      expected_recipients: expected_recipients
    )
  end

  def make_challenge(recipient:, splits: nil)
    request = {
      "amount" => "1000000",
      "currency" => "USD",
      "recipient" => recipient
    }
    request["methodDetails"] = {"splits" => splits} if splits

    Mpp::Challenge.new(
      id: "test-id",
      method: "tempo",
      intent: "charge",
      request: request,
      realm: "test.example.com"
    )
  end

  def stub_account
    Struct.new(:address, :type).new("0x0000000000000000000000000000000000000001", "local")
  end

  def test_rejects_unexpected_recipient
    method = make_method(expected_recipients: [ALLOWED])
    challenge = make_challenge(recipient: OTHER)

    err = assert_raises(ArgumentError) do
      method.create_credential(challenge)
    end
    assert_equal "Unexpected recipient: #{OTHER}", err.message
  end

  def test_allows_expected_recipient
    method = make_method(expected_recipients: [ALLOWED])
    challenge = make_challenge(recipient: ALLOWED)

    # Should pass recipient validation — no ArgumentError about unexpected recipient
    err = assert_raises(Exception) { method.create_credential(challenge) }
    refute_match(/Unexpected recipient/, err.message)
  end

  def test_expected_recipients_case_insensitive
    method = make_method(expected_recipients: [ALLOWED.downcase])
    challenge = make_challenge(recipient: ALLOWED.upcase)

    err = assert_raises(Exception) { method.create_credential(challenge) }
    refute_match(/Unexpected recipient/, err.message)
  end

  def test_rejects_unexpected_split_recipient
    method = make_method(expected_recipients: [ALLOWED])
    challenge = make_challenge(
      recipient: ALLOWED,
      splits: [{"recipient" => OTHER, "amount" => "500000"}]
    )

    err = assert_raises(ArgumentError) do
      method.create_credential(challenge)
    end
    assert_equal "Unexpected split recipient: #{OTHER}", err.message
  end

  def test_allows_expected_split_recipients
    method = make_method(expected_recipients: [ALLOWED, OTHER])
    challenge = make_challenge(
      recipient: ALLOWED,
      splits: [{"recipient" => OTHER, "amount" => "500000"}]
    )

    err = assert_raises(Exception) { method.create_credential(challenge) }
    refute_match(/Unexpected.*recipient/, err.message)
  end

  def test_skips_validation_when_no_allowlist
    method = Mpp::Methods::Tempo::TempoMethod.new(account: stub_account)
    challenge = make_challenge(recipient: OTHER)

    err = assert_raises(Exception) { method.create_credential(challenge) }
    refute_match(/Unexpected recipient/, err.message)
  end
end
