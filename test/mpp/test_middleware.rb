# frozen_string_literal: true

require "test_helper"

class TestMiddleware < Minitest::Test
  def setup
    @secret_key = "test-middleware-secret"
    @realm = "api.example.com"
  end

  def test_passes_through_when_no_charge
    app = ->(_env) { [200, {"Content-Type" => "text/plain"}, ["OK"]] }
    middleware = Mpp::Server::Middleware.new(app, handler: mock_handler)

    status, headers, body = middleware.call(minimal_env)

    assert_equal 200, status
    assert_equal ["OK"], body
    assert_equal "text/plain", headers["Content-Type"]
  end

  def test_returns_402_when_charge_requested_without_auth
    app = lambda { |env|
      env["mpp.charge"] = {amount: "1.00"}
      [200, {}, ["OK"]]
    }
    middleware = Mpp::Server::Middleware.new(app, handler: mock_handler)

    status, headers, _body = middleware.call(minimal_env)

    assert_equal 402, status
    assert headers.key?("WWW-Authenticate")
    assert_equal "application/problem+json", headers["Content-Type"]
  end

  def test_attaches_receipt_on_successful_payment
    # Build a valid credential from a challenge
    handler = mock_handler
    challenge = handler.charge(nil, "1.00")
    assert_instance_of Mpp::Challenge, challenge

    # Build a valid credential
    echo = challenge.to_echo
    credential = Mpp::Credential.new(
      challenge: echo,
      payload: {"type" => "test", "data" => "ok"}
    )
    auth_header = credential.to_authorization

    app = lambda { |env|
      env["mpp.charge"] = {amount: "1.00"}
      [200, {}, ["OK"]]
    }
    middleware = Mpp::Server::Middleware.new(app, handler: handler)

    env = minimal_env.merge("HTTP_AUTHORIZATION" => auth_header)
    status, headers, body = middleware.call(env)

    assert_equal 200, status
    assert headers.key?("Payment-Receipt")
    assert_equal ["OK"], body
  end

  private

  def minimal_env
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/resource"
    }
  end

  def mock_handler
    verify_fn = lambda { |credential, _request|
      Mpp::Receipt.success("ref-#{credential.challenge.id[0..7]}")
    }
    intent = Mpp::Server::FunctionalIntent.new("charge", &verify_fn)

    stub_method = Object.new
    stub_method.define_singleton_method(:name) { "tempo" }
    stub_method.define_singleton_method(:intents) { {"charge" => intent} }
    stub_method.define_singleton_method(:currency) { "0x20c0000000000000000000000000000000000000" }
    stub_method.define_singleton_method(:recipient) { "0x1234567890abcdef1234567890abcdef12345678" }
    stub_method.define_singleton_method(:decimals) { 6 }

    Mpp::Server::MppHandler.new(
      method: stub_method,
      realm: @realm,
      secret_key: @secret_key
    )
  end
end
