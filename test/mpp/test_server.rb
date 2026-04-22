# frozen_string_literal: true

require "test_helper"

class MockIntent
  attr_reader :name

  def initialize(name: "charge")
    @name = name
  end

  def verify(_credential, _request)
    Mpp::Receipt.success("0xmocktxhash", method: "tempo")
  end
end

class MockMethod
  attr_reader :name, :intents, :currency, :recipient, :decimals, :chain_id

  def initialize(intents: {}, currency: nil, recipient: nil, decimals: 6, chain_id: nil)
    @name = "tempo"
    @intents = intents
    @currency = currency
    @recipient = recipient
    @decimals = decimals
    @chain_id = chain_id
  end
end

class TestServerVerify < Minitest::Test
  SECRET = "test-server-secret"
  REALM = "api.example.com"

  def setup
    @intent = MockIntent.new
  end

  def test_returns_challenge_when_no_authorization
    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: nil,
      intent: @intent,
      request: {"amount" => "1000000"},
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Challenge, result
    assert_equal "tempo", result.method
    assert_equal "charge", result.intent
  end

  def test_returns_challenge_when_non_payment_scheme
    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: "Bearer token123",
      intent: @intent,
      request: {"amount" => "1000000"},
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Challenge, result
  end

  def test_returns_challenge_for_invalid_credential
    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: "Payment invalidbase64!!!",
      intent: @intent,
      request: {"amount" => "1000000"},
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Challenge, result
  end

  def test_successful_verification
    request = {"amount" => "1000000"}
    challenge = Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: request,
      expires: Mpp::Expires.minutes(5)
    )
    echo = challenge.to_echo
    credential = Mpp::Credential.new(
      challenge: echo,
      payload: {"type" => "transaction", "signature" => "0xabc"},
      source: "did:pkh:eip155:4217:0x1234"
    )
    auth_header = credential.to_authorization

    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: auth_header,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Array, result
    assert_equal 2, result.length
    cred, receipt = result

    assert_instance_of Mpp::Credential, cred
    assert_instance_of Mpp::Receipt, receipt
    assert_equal "success", receipt.status
  end

  def test_rejects_wrong_secret
    request = {"amount" => "1000000"}
    challenge = Mpp::Challenge.create(
      secret_key: "different-secret",
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: request,
      expires: Mpp::Expires.minutes(5)
    )
    echo = challenge.to_echo
    credential = Mpp::Credential.new(challenge: echo, payload: {"type" => "hash", "hash" => "0x123"})
    auth_header = credential.to_authorization

    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: auth_header,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Challenge, result
  end

  def test_rejects_expired_challenge
    request = {"amount" => "1000000"}
    challenge = Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: request,
      expires: "2020-01-01T00:00:00.000Z"
    )
    echo = challenge.to_echo
    credential = Mpp::Credential.new(challenge: echo, payload: {"type" => "hash", "hash" => "0x123"})
    auth_header = credential.to_authorization

    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: auth_header,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Challenge, result
  end

  def test_rejects_mismatched_request
    request = {"amount" => "1000000"}
    challenge = Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: {"amount" => "9999999"},
      expires: Mpp::Expires.minutes(5)
    )
    echo = challenge.to_echo
    credential = Mpp::Credential.new(challenge: echo, payload: {"type" => "hash", "hash" => "0x123"})
    auth_header = credential.to_authorization

    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: auth_header,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Challenge, result
  end

  def test_challenge_has_expires
    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: nil,
      intent: @intent,
      request: {"amount" => "1000000"},
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Challenge, result
    refute_nil result.expires
  end

  def test_transforms_units
    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: nil,
      intent: @intent,
      request: {"amount" => "1.5", "decimals" => 6},
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Challenge, result
    assert_equal "1500000", result.request["amount"]
    refute result.request.key?("decimals")
  end
end

class TestMppHandler < Minitest::Test
  def test_charge_returns_challenge_without_auth
    intent = MockIntent.new
    method = MockMethod.new(
      intents: {"charge" => intent},
      currency: "0x20c0000000000000000000000000000000000000",
      recipient: "0x742d35Cc6634c0532925a3b844bC9e7595F8fE00"
    )
    handler = Mpp::Server::MppHandler.new(
      method: method,
      realm: "api.example.com",
      secret_key: "test-secret"
    )

    result = handler.charge(nil, "0.50")

    assert_instance_of Mpp::Challenge, result
    assert_equal "500000", result.request["amount"]
    assert_equal "0x20c0000000000000000000000000000000000000", result.request["currency"]
    assert_equal "0x742d35Cc6634c0532925a3b844bC9e7595F8fE00", result.request["recipient"]
  end

  def test_charge_with_fee_payer
    intent = MockIntent.new
    method = MockMethod.new(
      intents: {"charge" => intent},
      currency: "0x20c0000000000000000000000000000000000000",
      recipient: "0x742d35Cc6634c0532925a3b844bC9e7595F8fE00"
    )
    handler = Mpp::Server::MppHandler.new(
      method: method,
      realm: "api.example.com",
      secret_key: "test-secret"
    )

    result = handler.charge(nil, "1.00", fee_payer: true, chain_id: 42_431)

    assert_instance_of Mpp::Challenge, result
    assert result.request.dig("methodDetails", "feePayer")
    assert_equal 42_431, result.request.dig("methodDetails", "chainId")
  end

  def test_charge_raises_without_intent
    method = MockMethod.new(intents: {})
    handler = Mpp::Server::MppHandler.new(
      method: method,
      realm: "api.example.com",
      secret_key: "test-secret"
    )
    assert_raises(ArgumentError) { handler.charge(nil, "1.00") }
  end

  def test_challenge_response
    challenge = Mpp::Challenge.create(
      secret_key: "test",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"}
    )
    response = Mpp::Server::Decorator.make_challenge_response(challenge, "api.example.com")

    assert_equal 402, response["status"]
    assert response["headers"].key?("WWW-Authenticate")
    assert_equal "application/problem+json", response["headers"]["Content-Type"]
  end
end

class TestDefaults < Minitest::Test
  def test_detect_realm_defaults_to_localhost
    # Save and clear env
    saved = Mpp::Server::Defaults::REALM_ENV_VARS.to_h { |v| [v, ENV.fetch(v, nil)] }
    saved.each_key { |v| ENV.delete(v) }

    assert_equal "localhost", Mpp::Server::Defaults.detect_realm
  ensure
    saved&.each { |v, val| ENV[v] = val }
  end

  def test_detect_realm_from_env
    ENV["MPP_REALM"] = "test.example.com"

    assert_equal "test.example.com", Mpp::Server::Defaults.detect_realm
  ensure
    ENV.delete("MPP_REALM")
  end

  def test_detect_secret_key_raises_when_missing
    ENV.delete("MPP_SECRET_KEY")
    assert_raises(ArgumentError) { Mpp::Server::Defaults.detect_secret_key }
  end

  def test_detect_secret_key_from_env
    ENV["MPP_SECRET_KEY"] = "my-secret"

    assert_equal "my-secret", Mpp::Server::Defaults.detect_secret_key
  ensure
    ENV.delete("MPP_SECRET_KEY")
  end
end
