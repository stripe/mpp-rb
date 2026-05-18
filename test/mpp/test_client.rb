# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

class MockClientMethod
  attr_reader :name

  def initialize(name: "tempo")
    @name = name
    @credential = nil
  end

  def create_credential(challenge)
    echo = challenge.to_echo
    Mpp::Credential.new(
      challenge: echo,
      payload: {"type" => "transaction", "signature" => "0xmocksig"},
      source: "did:pkh:eip155:4217:0xmockaddr"
    )
  end
end

class FailingClientMethod < MockClientMethod
  def create_credential(_challenge)
    raise Mpp::VerificationFailedError.new(reason: "client signing failed")
  end
end

class TestClientTransport < Minitest::Test
  def setup
    @method = MockClientMethod.new
    @transport = Mpp::Client::Transport.new(methods: [@method])
  end

  def test_passes_through_non_402_response
    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 200, body: '{"data":"ok"}')

    response = @transport.get("https://api.example.com/resource")

    assert_equal "200", response.code
  end

  def test_passes_through_402_without_payment_scheme
    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, body: "Payment required", headers: {"WWW-Authenticate" => "Bearer realm=test"})

    response = @transport.get("https://api.example.com/resource")

    assert_equal "402", response.code
  end

  def test_handles_402_with_payment_challenge
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: Mpp::Expires.minutes(5)
    )
    www_auth = challenge.to_www_authenticate("api.example.com")

    # First request returns 402, second returns 200
    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, headers: {"WWW-Authenticate" => www_auth})
      .then
      .to_return(status: 200, body: '{"data":"paid"}')

    response = @transport.get("https://api.example.com/resource")

    assert_equal "200", response.code
    assert_equal '{"data":"paid"}', response.body
  end

  def test_retry_includes_authorization_header
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: Mpp::Expires.minutes(5)
    )
    www_auth = challenge.to_www_authenticate("api.example.com")

    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, headers: {"WWW-Authenticate" => www_auth})
      .then
      .to_return(status: 200, body: "ok")

    @transport.get("https://api.example.com/resource")

    # Verify the retry had an Authorization header
    assert_requested(:get, "https://api.example.com/resource",
      headers: {"Authorization" => /^Payment /},
      times: 1)
  end

  def test_skips_expired_challenge
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: "2020-01-01T00:00:00.000Z"
    )
    www_auth = challenge.to_www_authenticate("api.example.com")

    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, headers: {"WWW-Authenticate" => www_auth})

    response = @transport.get("https://api.example.com/resource")

    assert_equal "402", response.code
  end

  def test_skips_unrecognized_method
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "unknown_method",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: Mpp::Expires.minutes(5)
    )
    www_auth = challenge.to_www_authenticate("api.example.com")

    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, headers: {"WWW-Authenticate" => www_auth})

    response = @transport.get("https://api.example.com/resource")

    assert_equal "402", response.code
  end

  def test_emits_client_lifecycle_events
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: Mpp::Expires.minutes(5)
    )
    www_auth = challenge.to_www_authenticate("api.example.com")
    events = []

    @transport.on_challenge_received do |payload|
      events << [Mpp::Events::CHALLENGE_RECEIVED, payload[:challenge].id]
      nil
    end
    @transport.on_credential_created do |payload|
      events << [Mpp::Events::CREDENTIAL_CREATED, payload[:credential].start_with?("Payment ")]
    end
    @transport.on_payment_response do |payload|
      events << [Mpp::Events::PAYMENT_RESPONSE, payload[:response].code]
    end
    @transport.on(Mpp::Events::ANY) do |event|
      events << [Mpp::Events::ANY, event.name]
    end

    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, headers: {"WWW-Authenticate" => www_auth})
      .then
      .to_return(status: 200, body: "paid")

    response = @transport.get("https://api.example.com/resource")

    assert_equal "200", response.code
    assert_equal [
      [Mpp::Events::CHALLENGE_RECEIVED, challenge.id],
      [Mpp::Events::ANY, Mpp::Events::CHALLENGE_RECEIVED],
      [Mpp::Events::CREDENTIAL_CREATED, true],
      [Mpp::Events::ANY, Mpp::Events::CREDENTIAL_CREATED],
      [Mpp::Events::PAYMENT_RESPONSE, "200"],
      [Mpp::Events::ANY, Mpp::Events::PAYMENT_RESPONSE]
    ], events
  end

  def test_challenge_received_can_override_credential
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: Mpp::Expires.minutes(5)
    )
    override = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "hash", "hash" => "0xoverride"}
    ).to_authorization

    @transport.on_challenge_received { |_payload| override }

    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, headers: {"WWW-Authenticate" => challenge.to_www_authenticate("api.example.com")})
      .then
      .to_return(status: 200, body: "paid")

    @transport.get("https://api.example.com/resource")

    assert_requested(:get, "https://api.example.com/resource",
      headers: {"Authorization" => override},
      times: 1)
  end

  def test_rejects_invalid_hook_credential_header
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: Mpp::Expires.minutes(5)
    )
    seen = []
    @transport.on_challenge_received { |_payload| "Payment valid\r\nX-Injected: true" }
    @transport.on_payment_failed { |payload| seen << payload[:error] }

    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, headers: {"WWW-Authenticate" => challenge.to_www_authenticate("api.example.com")})

    error = assert_raises(ArgumentError) do
      @transport.get("https://api.example.com/resource")
    end

    assert_equal "Credential contains invalid header characters", error.message
    assert_equal [error], seen
  end

  def test_emits_payment_failed_for_challenge_parse_failure
    seen = []
    @transport.on_payment_failed { |payload| seen << payload[:error] }

    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, headers: {"WWW-Authenticate" => "Payment invalidbase64!!!"})

    response = @transport.get("https://api.example.com/resource")

    assert_equal "402", response.code
    assert_equal 1, seen.length
    assert_instance_of Mpp::ParseError, seen.first
  end

  def test_client_hook_errors_do_not_stop_payment_flow
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: Mpp::Expires.minutes(5)
    )
    @transport.on_credential_created { |_payload| raise "observer failed" }

    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, headers: {"WWW-Authenticate" => challenge.to_www_authenticate("api.example.com")})
      .then
      .to_return(status: 200, body: "paid")

    response = @transport.get("https://api.example.com/resource")

    assert_equal "200", response.code
  end

  def test_emits_payment_failed_when_credential_creation_fails
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: Mpp::Expires.minutes(5)
    )
    transport = Mpp::Client::Transport.new(methods: [FailingClientMethod.new])
    seen = []
    transport.on_payment_failed do |payload|
      seen << [payload[:challenge].id, payload[:error].message]
    end

    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, headers: {"WWW-Authenticate" => challenge.to_www_authenticate("api.example.com")})

    error = assert_raises(Mpp::VerificationFailedError) do
      transport.get("https://api.example.com/resource")
    end

    assert_equal "Payment verification failed: client signing failed.", error.message
    assert_equal [[challenge.id, "Payment verification failed: client signing failed."]], seen
  end
end

class TestClientConvenience < Minitest::Test
  def test_module_level_get
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      expires: Mpp::Expires.minutes(5)
    )
    www_auth = challenge.to_www_authenticate("api.example.com")

    stub_request(:get, "https://api.example.com/resource")
      .to_return(status: 402, headers: {"WWW-Authenticate" => www_auth})
      .then
      .to_return(status: 200, body: "paid")

    response = Mpp::Client.get("https://api.example.com/resource", methods: [MockClientMethod.new])

    assert_equal "200", response.code
  end
end
