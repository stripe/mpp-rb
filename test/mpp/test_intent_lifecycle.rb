# frozen_string_literal: true

require "test_helper"

class TestIntentLifecycle < Minitest::Test
  SECRET = "lifecycle-secret"
  REALM = "api.example.com"

  class TwoPhaseIntent
    attr_reader :calls, :name

    def initialize
      @name = "charge"
      @calls = []
    end

    def validate(credential, request)
      @calls << [:validate, credential, request]
      {validated: true}
    end

    def broadcast(credential, request)
      @calls << [:broadcast, credential, request]
      Mpp::Receipt.success("0xlifecycle", method: "test")
    end
  end

  class FailingIntent < TwoPhaseIntent
    def validate(credential, request)
      super
      raise Mpp::VerificationError, "invalid credential"
    end
  end

  class LegacyIntent
    attr_reader :name, :calls

    def initialize
      @name = "charge"
      @calls = []
    end

    def verify(credential, request)
      @calls << [credential, request]
      Mpp::Receipt.success("0xlegacy", method: "test")
    end
  end

  class IncompleteIntent
    def validate(_credential, _request)
      {}
    end
  end

  def test_validate_runs_before_broadcast
    intent = TwoPhaseIntent.new
    credential = credential_for
    request = {"amount" => "1000000"}

    receipt = Mpp::Server::IntentLifecycle.call(intent, credential, request)

    assert_equal "0xlifecycle", receipt.reference
    assert_equal [:validate, :broadcast], intent.calls.map(&:first)
  end

  def test_broadcast_does_not_run_when_validation_fails
    intent = FailingIntent.new

    assert_raises(Mpp::VerificationError) do
      Mpp::Server::IntentLifecycle.call(intent, credential_for, {"amount" => "1000000"})
    end

    assert_equal [:validate], intent.calls.map(&:first)
  end

  def test_legacy_verify_intents_continue_to_work
    intent = LegacyIntent.new

    receipt = Mpp::Server::IntentLifecycle.call(intent, credential_for, {"amount" => "1000000"})

    assert_equal "0xlegacy", receipt.reference
    assert_equal 1, intent.calls.length
  end

  def test_partial_two_phase_intents_are_rejected
    error = assert_raises(ArgumentError) do
      Mpp::Server::IntentLifecycle.call(IncompleteIntent.new, credential_for, {})
    end

    assert_equal "intent must implement both #validate and #broadcast", error.message
  end

  def test_server_verifier_uses_two_phase_lifecycle
    intent = TwoPhaseIntent.new
    request = {"amount" => "1000000"}
    challenge = Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: request,
      expires: Mpp::Expires.minutes(5)
    )

    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: Mpp::Credential.new(challenge: challenge.to_echo, payload: {}).to_authorization,
      intent: intent,
      request: request,
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Array, result
    assert_equal [:validate, :broadcast], intent.calls.map(&:first)
  end

  private

  def credential_for
    challenge = Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: Mpp::Expires.minutes(5)
    )
    Mpp::Credential.new(challenge: challenge.to_echo, payload: {})
  end
end
