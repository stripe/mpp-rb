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
