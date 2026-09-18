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
  attr_reader :name, :intents, :currency, :recipient, :decimals, :chain_id, :fee_payer,
    :on_payment_success

  def initialize(intents: {}, currency: nil, recipient: nil, decimals: 6, chain_id: nil,
    fee_payer: nil, name: "tempo", on_payment_success: nil)
    @name = name
    @intents = intents
    @currency = currency
    @recipient = recipient
    @decimals = decimals
    @chain_id = chain_id
    @fee_payer = fee_payer
    @on_payment_success = on_payment_success
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

  def test_verification_emits_payment_success
    request = {"amount" => "1000000"}
    challenge = Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: request,
      expires: Mpp::Expires.minutes(5)
    )
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "transaction", "signature" => "0xabc"}
    )
    events = Mpp::Events.server_dispatcher
    seen = []
    events.on(Mpp::Events::PAYMENT_SUCCESS) do |payload|
      seen << [payload[:challenge].id, payload[:receipt].status, payload[:method]]
    end

    Mpp::Server::Verify.verify_or_challenge(
      authorization: credential.to_authorization,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET,
      events: events
    )

    assert_equal [[challenge.id, "success", {name: "tempo", intent: "charge"}]], seen
  end

  def test_successful_verification_with_body_digest
    request = {"amount" => "1000000"}
    body = "{\"query\":\"paid\"}"
    challenge = Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: request,
      expires: Mpp::Expires.minutes(5),
      digest: Mpp::BodyDigest.compute(body)
    )
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "transaction", "signature" => "0xabc"},
      source: "did:pkh:eip155:4217:0x1234"
    )

    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: credential.to_authorization,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET,
      body: body
    )

    assert_instance_of Array, result
    _credential, receipt = result
    assert_equal "success", receipt.status
  end

  def test_rejects_mismatched_body_digest
    request = {"amount" => "1000000"}
    challenge = Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: request,
      expires: Mpp::Expires.minutes(5),
      digest: Mpp::BodyDigest.compute("{\"query\":\"paid\"}")
    )
    credential = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"type" => "hash", "hash" => "0x123"})

    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: credential.to_authorization,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET,
      body: "{\"query\":\"tampered\"}"
    )

    assert_instance_of Mpp::Challenge, result
  end

  def test_rejects_digest_bound_credential_without_body
    request = {"amount" => "1000000"}
    challenge = Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: request,
      expires: Mpp::Expires.minutes(5),
      digest: Mpp::BodyDigest.compute("{\"query\":\"paid\"}")
    )
    credential = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"type" => "hash", "hash" => "0x123"})

    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: credential.to_authorization,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET
    )

    assert_instance_of Mpp::Challenge, result
    assert_nil result.digest
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

  def test_verification_failure_emits_payment_failed_and_challenge_created
    request = {"amount" => "1000000"}
    challenge = Mpp::Challenge.create(
      secret_key: "different-secret",
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: request,
      expires: Mpp::Expires.minutes(5)
    )
    credential = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"type" => "hash", "hash" => "0x123"})
    events = Mpp::Events.server_dispatcher
    seen = []
    events.on(Mpp::Events::PAYMENT_FAILED) do |payload|
      seen << [Mpp::Events::PAYMENT_FAILED, payload[:submitted_challenge].id, payload[:error].class]
    end
    events.on(Mpp::Events::CHALLENGE_CREATED) do |payload|
      seen << [Mpp::Events::CHALLENGE_CREATED, payload[:challenge].id, payload[:error].class]
    end

    result = Mpp::Server::Verify.verify_or_challenge(
      authorization: credential.to_authorization,
      intent: @intent,
      request: request,
      realm: REALM,
      secret_key: SECRET,
      events: events
    )

    assert_instance_of Mpp::Challenge, result
    assert_equal Mpp::Events::PAYMENT_FAILED, seen[0][0]
    assert_equal challenge.id, seen[0][1]
    assert_equal Mpp::InvalidChallengeError, seen[0][2]
    assert_equal Mpp::Events::CHALLENGE_CREATED, seen[1][0]
    assert_equal result.id, seen[1][1]
    assert_equal Mpp::InvalidChallengeError, seen[1][2]
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
  CURRENCY = "0x20c0000000000000000000000000000000000000"
  RECIPIENT = "0x742d35Cc6634c0532925a3b844bC9e7595F8fE00"

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

  def test_charge_auto_advertises_method_fee_payer
    intent = MockIntent.new
    method = MockMethod.new(
      intents: {"charge" => intent},
      currency: Mpp::Methods::Tempo::Defaults::PATH_USD,
      recipient: "0x#{"0" * 39}1",
      fee_payer: Object.new
    )
    handler = Mpp::Server::MppHandler.new(
      method: method,
      realm: "api.example.com",
      secret_key: "test-secret"
    )

    result = handler.charge(nil, "1.00", chain_id: 42_431)

    assert_instance_of Mpp::Challenge, result
    assert result.request.dig("methodDetails", "feePayer")
  end

  def test_charge_can_disable_method_fee_payer
    intent = MockIntent.new
    method = MockMethod.new(
      intents: {"charge" => intent},
      currency: Mpp::Methods::Tempo::Defaults::PATH_USD,
      recipient: "0x#{"0" * 39}1",
      fee_payer: Object.new
    )
    handler = Mpp::Server::MppHandler.new(
      method: method,
      realm: "api.example.com",
      secret_key: "test-secret"
    )

    result = handler.charge(nil, "1.00", fee_payer: false, chain_id: 42_431)

    assert_instance_of Mpp::Challenge, result
    refute result.request.dig("methodDetails", "feePayer")
  end

  def test_charge_binds_external_id
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

    result = handler.charge(nil, "1.00", external_id: "order-123")

    assert_instance_of Mpp::Challenge, result
    assert_equal "order-123", result.request["externalId"]
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

  def test_handler_exposes_server_lifecycle_hooks
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
    seen = []
    off = handler.on_challenge_created do |payload|
      seen << [Mpp::Events::CHALLENGE_CREATED, payload[:request]["amount"]]
    end
    handler.on(Mpp::Events::ANY) do |event|
      seen << [Mpp::Events::ANY, event.name]
    end

    handler.charge(nil, "0.50")
    off.call
    handler.charge(nil, "0.50")

    assert_equal [
      [Mpp::Events::CHALLENGE_CREATED, "500000"],
      [Mpp::Events::ANY, Mpp::Events::CHALLENGE_CREATED],
      [Mpp::Events::ANY, Mpp::Events::CHALLENGE_CREATED]
    ], seen
  end

  def test_server_hook_errors_do_not_stop_charge
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
    handler.on_challenge_created { |_payload| raise "observer failed" }

    result = handler.charge(nil, "0.50")

    assert_instance_of Mpp::Challenge, result
  end

  def test_method_payment_success_hook_preserves_global_observers
    seen = []
    method = payment_method(on_payment_success: ->(payload) { seen << [:method, payload] })
    events = Mpp::Events.server_dispatcher
    events.on(Mpp::Events::PAYMENT_SUCCESS) { |payload| seen << [:global, payload] }
    handler = payment_handler(method, events: events)

    result = pay(handler)

    assert_instance_of Array, result
    assert_equal [:global, :method], seen.map(&:first).sort
    seen.each do |_kind, payload|
      assert_equal({name: "tempo", intent: "charge"}, payload[:method])
      assert_equal "success", payload[:receipt].status
    end
    assert_same seen.find { |kind, _payload| kind == :global }.last,
      seen.find { |kind, _payload| kind == :method }.last
  end

  def test_method_payment_success_hook_matches_the_intent_name_not_its_registry_key
    seen = []
    intent = MockIntent.new(name: "pay")
    method = MockMethod.new(
      intents: {"charge" => intent},
      currency: CURRENCY,
      recipient: RECIPIENT,
      on_payment_success: ->(payload) { seen << payload }
    )

    pay(payment_handler(method))

    assert_equal 1, seen.length
    assert_equal({name: "tempo", intent: "pay"}, seen.first[:method])
  end

  def test_method_payment_success_hooks_are_isolated_per_handler_with_a_shared_dispatcher
    seen = []
    events = Mpp::Events.server_dispatcher
    first = payment_method(on_payment_success: ->(_payload) { seen << :first })
    second = payment_method(on_payment_success: ->(_payload) { seen << :second })
    first_handler = payment_handler(first, events: events)
    payment_handler(second, events: events)

    pay(first_handler)

    assert_equal [:first], seen

    reused = payment_method(on_payment_success: ->(_payload) { seen << :reused })
    first_handler = payment_handler(reused, events: events)
    payment_handler(reused, events: events)

    pay(first_handler)

    assert_equal [:first, :reused], seen
  end

  def test_method_payment_success_hook_errors_do_not_stop_payment
    method = payment_method(on_payment_success: ->(_payload) { raise "hook failed" })
    handler = payment_handler(method)

    result = pay(handler)

    assert_instance_of Array, result
    assert_equal "success", result.last.status
  end

  def test_method_payment_success_hook_does_not_run_when_verification_fails
    calls = 0
    intent = Mpp::Server::FunctionalIntent.new("charge") do |_credential, _request|
      raise Mpp::VerificationError, "payment failed"
    end
    method = MockMethod.new(
      intents: {"charge" => intent},
      currency: CURRENCY,
      recipient: RECIPIENT,
      on_payment_success: ->(_payload) { calls += 1 }
    )
    handler = payment_handler(method)
    challenge = handler.charge(nil, "0.50")
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test"}
    )

    assert_raises(Mpp::VerificationError) do
      handler.charge(credential.to_authorization, "0.50")
    end
    assert_equal 0, calls
  end

  def test_requires_auth_advertises_payment_authorization_header
    handler = requires_auth_handler
    result = handler.charge("Bearer app-token", "0.50")

    assert_instance_of Mpp::Challenge, result
    assert_equal Mpp::PAYMENT_AUTHORIZATION_HEADER, result.header
    www = handler.challenge_response(result)["headers"]["WWW-Authenticate"]
    assert_includes www, %(header="#{Mpp::PAYMENT_AUTHORIZATION_HEADER}")
    assert_includes handler.challenge_response(result)["headers"]["Vary"], Mpp::PAYMENT_AUTHORIZATION_HEADER
  end

  def test_requires_auth_verifies_payment_authorization_and_ignores_bearer
    handler = requires_auth_handler
    challenge = handler.charge("Bearer app-token", "0.50")
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test"}
    )

    ignored = handler.charge(credential.to_authorization, "0.50")
    assert_instance_of Mpp::Challenge, ignored

    paid = handler.charge(
      "Bearer app-token",
      "0.50",
      payment_authorization: credential.to_authorization
    )
    assert_instance_of Array, paid
    assert_equal "success", paid.last.status
  end

  private

  def requires_auth_handler
    intent = MockIntent.new
    method = MockMethod.new(
      intents: {"charge" => intent},
      currency: Mpp::Methods::Tempo::Defaults::PATH_USD,
      recipient: "0x#{"0" * 39}1"
    )
    Mpp::Server::MppHandler.new(
      method: method,
      realm: "api.example.com",
      secret_key: "test-secret",
      requires_auth: true
    )
  end

  def payment_method(on_payment_success: nil)
    MockMethod.new(
      intents: {"charge" => MockIntent.new},
      currency: CURRENCY,
      recipient: RECIPIENT,
      on_payment_success: on_payment_success
    )
  end

  def payment_handler(method, events: nil)
    Mpp::Server::MppHandler.new(
      method: method,
      realm: "api.example.com",
      secret_key: "test-secret",
      events: events
    )
  end

  def pay(handler)
    challenge = handler.charge(nil, "0.50")
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test"}
    )
    handler.charge(credential.to_authorization, "0.50")
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
