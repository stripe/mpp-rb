# frozen_string_literal: true

require "test_helper"

class TestIntentLifecycle < Minitest::Test
  SECRET = "lifecycle-secret"
  REALM = "api.example.com"
  REQUEST = {"amount" => "1000000", "currency" => "usd", "recipient" => "merchant"}.freeze

  # Only the server's method/binding interface is needed to exercise dispatch.
  class FakeMethod
    attr_reader :name, :intents, :currency, :recipient, :decimals

    def initialize(intent)
      @name = "test"
      @intents = {"charge" => intent}
      @currency = "usd"
      @recipient = "merchant"
      @decimals = 6
    end

    def bind_x402_credential(signature, challenge:, **)
      Mpp::Credential.new(challenge: challenge.to_echo, payload: {"signature" => signature})
    end
  end

  class TwoPhaseIntent
    attr_reader :calls, :name

    def initialize
      @name = "charge"
      @calls = []
    end

    def validate(credential, request)
      @calls << [:validate, credential, request]
      Mpp::Validation.new(
        challenge: credential.challenge, credential: credential,
        details: {validated: true}, intent: name, method: "test",
        request: request, source: credential.source
      )
    end

    def broadcast(credential, request)
      @calls << [:broadcast, credential, request]
      Mpp::Receipt.success("0xlifecycle", method: "test")
    end

    def verify(_credential, _request)
      raise "The server must prefer validate/broadcast over legacy verify"
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

  def test_validate_returns_a_structured_record_without_broadcasting
    intent = TwoPhaseIntent.new
    credential = credential_for.with(source: "test-payer")

    validation = intent.validate(credential, REQUEST)

    assert_instance_of Mpp::Validation, validation
    assert_equal [:challenge, :credential, :details, :intent, :method, :request, :source], validation.members.sort
    assert_same credential.challenge, validation.challenge
    assert_same credential, validation.credential
    assert_same REQUEST, validation.request
    assert_equal({validated: true}, validation.details)
    assert_equal "charge", validation.intent
    assert_equal "test", validation.method
    assert_equal "test-payer", validation.source
    assert validation.frozen?
    assert_equal [:validate], intent.calls.map(&:first)
  end

  def test_validation_source_is_optional
    credential = credential_for
    validation = Mpp::Validation.new(
      challenge: credential.challenge, credential: credential,
      intent: "charge", method: "test", request: REQUEST, details: {}
    )

    assert_equal({}, validation.details)
    assert_nil validation.source
  end

  def test_validate_runs_before_broadcast
    intent = TwoPhaseIntent.new
    credential = credential_for
    request = {"amount" => "1000000"}

    receipt = Mpp::Server::IntentLifecycle.call(intent, credential, request)

    assert_equal "0xlifecycle", receipt.reference
    assert_equal [[:validate, credential, request], [:broadcast, credential, request]], intent.calls
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

  def test_charge_uses_two_phase_lifecycle
    intent = TwoPhaseIntent.new
    server = server_for(intent)
    challenge = server.charge(nil, "1.00")
    assert_empty intent.calls
    credential = credential_for(challenge)

    result = server.charge(credential.to_authorization, "1.00")

    assert_equal "0xlifecycle", result.last.reference
    assert_equal [[:validate, credential, challenge.request], [:broadcast, credential, challenge.request]], intent.calls
  end

  def test_charge_validation_failure_emits_failure_without_broadcast
    intent = FailingIntent.new
    server = server_for(intent)
    events = []
    server.on_payment_failed { |payload| events << payload[:error] }
    server.on_payment_success { |_payload| flunk "validation failure must not emit success" }
    credential = credential_for(server.charge(nil, "1.00"))

    error = assert_raises(Mpp::VerificationError) do
      server.charge(credential.to_authorization, "1.00")
    end

    assert_equal [error], events
    assert_equal [:validate], intent.calls.map(&:first)
  end

  def test_composed_offer_uses_two_phase_lifecycle
    intent = TwoPhaseIntent.new
    server = server_for(intent)
    payment = server.compose([server.method, {amount: "1.00"}])
    challenge = payment.call.challenges.first
    assert_empty intent.calls

    result = payment.call(authorization: credential_for(challenge).to_authorization)

    refute result.payment_required?
    assert_equal "0xlifecycle", result.receipt.reference
    assert_equal [:validate, :broadcast], intent.calls.map(&:first)
  end

  def test_x402_uses_two_phase_lifecycle
    intent = TwoPhaseIntent.new

    credential, receipt = server_for(intent).charge(nil, "1.00", payment_signature: "test-signature")

    assert_equal "test-signature", credential.payload["signature"]
    assert_equal "0xlifecycle", receipt.reference
    assert_equal [[:validate, credential, REQUEST], [:broadcast, credential, REQUEST]], intent.calls
  end

  def test_x402_validation_failure_returns_challenge_without_broadcast
    intent = FailingIntent.new

    result = server_for(intent).charge(nil, "1.00", payment_signature: "test-signature")

    assert_instance_of Mpp::Challenge, result
    assert_equal [:validate], intent.calls.map(&:first)
  end

  def test_mcp_uses_two_phase_lifecycle
    intent = TwoPhaseIntent.new
    challenge = mcp_verify(intent)
    assert_empty intent.calls
    credential = Mpp::Extensions::MCP::MCPCredential.new(challenge: challenge, payload: {})

    _credential, receipt = mcp_verify(intent, meta: credential.to_meta)

    assert_equal "0xlifecycle", receipt.reference
    assert_equal challenge.id, receipt.challenge_id
    assert_equal [[:validate, credential.to_core, REQUEST], [:broadcast, credential.to_core, REQUEST]], intent.calls
  end

  def test_mcp_validation_failure_is_translated_without_broadcast
    intent = FailingIntent.new
    credential = Mpp::Extensions::MCP::MCPCredential.new(challenge: mcp_verify(intent), payload: {})

    assert_raises(Mpp::Extensions::MCP::PaymentVerificationError) do
      mcp_verify(intent, meta: credential.to_meta)
    end

    assert_equal [:validate], intent.calls.map(&:first)
  end

  private

  def server_for(intent)
    Mpp.create(method: FakeMethod.new(intent), realm: REALM, secret_key: SECRET)
  end

  def mcp_verify(intent, meta: nil)
    Mpp::Extensions::MCP.verify_or_challenge(
      meta: meta, intent: intent, request: REQUEST, method: "test", realm: REALM, secret_key: SECRET
    )
  end

  def credential_for(challenge = nil)
    challenge ||= Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "test",
      intent: "charge",
      request: REQUEST,
      expires: Mpp::Expires.minutes(5)
    )
    Mpp::Credential.new(challenge: challenge.to_echo, payload: {})
  end
end
