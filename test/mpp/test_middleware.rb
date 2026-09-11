# frozen_string_literal: true

require "test_helper"
require "stringio"

class TestMiddleware < Minitest::Test
  def setup
    @secret_key = "test-middleware-secret"
    @realm = "api.example.com"
  end

  def test_app_does_not_run_when_payment_fails
    invocations = 0
    app = lambda { |_env|
      invocations += 1
      [200, {}, ["OK"]]
    }
    pricing = ->(_env) { {amount: "1.00"} }
    middleware = Mpp::Server::Middleware.new(app, handler: mock_handler, pricing: pricing)

    status, _headers, _body = middleware.call(minimal_env)

    assert_equal 402, status
    assert_equal 0, invocations, "App handler must NOT run when payment verification fails"
  end

  def test_app_does_not_run_with_garbage_authorization
    invocations = 0
    app = lambda { |_env|
      invocations += 1
      [200, {}, ["OK"]]
    }
    pricing = ->(_env) { {amount: "1.00"} }
    middleware = Mpp::Server::Middleware.new(app, handler: mock_handler, pricing: pricing)

    status, _headers, _body = middleware.call(
      minimal_env.merge("HTTP_AUTHORIZATION" => "garbage-not-a-real-credential")
    )

    assert_equal 402, status
    assert_equal 0, invocations, "App handler must NOT run with invalid authorization"
  end

  def test_passes_through_when_pricing_returns_nil
    app = ->(_env) { [200, {"Content-Type" => "text/plain"}, ["OK"]] }
    pricing = ->(_env) {}
    middleware = Mpp::Server::Middleware.new(app, handler: mock_handler, pricing: pricing)

    status, headers, body = middleware.call(minimal_env)

    assert_equal 200, status
    assert_equal ["OK"], body
    assert_equal "text/plain", headers["Content-Type"]
  end

  def test_returns_402_when_no_auth_header
    app = ->(_env) { [200, {}, ["OK"]] }
    pricing = ->(_env) { {amount: "1.00"} }
    middleware = Mpp::Server::Middleware.new(app, handler: mock_handler, pricing: pricing)

    status, headers, _body = middleware.call(minimal_env)

    assert_equal 402, status
    assert headers.key?("WWW-Authenticate")
    assert_equal "application/problem+json", headers["Content-Type"]
    assert_equal "no-store", headers["Cache-Control"]
    assert_vary_authorization headers
  end

  def test_attaches_receipt_on_successful_payment
    handler = mock_handler
    pricing = ->(_env) { {amount: "1.00"} }

    # Get a challenge first
    challenge = handler.charge(nil, "1.00", mppx_scope: {"resource" => "/resource"})
    assert_instance_of Mpp::Challenge, challenge

    # Build a valid credential
    echo = challenge.to_echo
    credential = Mpp::Credential.new(
      challenge: echo,
      payload: {"type" => "test", "data" => "ok"}
    )
    auth_header = credential.to_authorization

    app = ->(_env) { [200, {}, ["OK"]] }
    middleware = Mpp::Server::Middleware.new(app, handler: handler, pricing: pricing)

    env = minimal_env.merge("HTTP_AUTHORIZATION" => auth_header)
    status, headers, body = middleware.call(env)

    assert_equal 200, status
    assert headers.key?("Payment-Receipt")
    assert_equal "private", headers["Cache-Control"]
    assert_vary_authorization headers
    assert_equal ["OK"], body
  end

  def test_preserves_downstream_cache_directives_on_receipt_response
    _, headers, = call_paid(->(_env) { [200, {"Cache-Control" => "max-age=60"}, ["OK"]] })

    assert_equal "max-age=60, private", headers["Cache-Control"]

    _, headers, = call_paid(->(_env) { [200, {"Cache-Control" => "max-age=60, private"}, ["OK"]] })

    assert_equal "max-age=60, private", headers["Cache-Control"]
  end

  def test_does_not_attach_receipt_when_downstream_returns_500
    status, headers, body = call_paid(->(_env) { [500, {}, ["boom"]] })

    assert_equal 500, status
    refute headers.key?("Payment-Receipt")
    assert_equal "no-store", headers["Cache-Control"]
    assert_equal ["boom"], body
  end

  def test_does_not_attach_receipt_when_downstream_returns_403
    status, headers, body = call_paid(->(_env) { [403, {}, ["denied"]] })

    assert_equal 403, status
    refute headers.key?("Payment-Receipt")
    assert_equal ["denied"], body
  end

  def test_rejects_paid_retry_with_different_auto_route_scope
    handler = mock_handler
    pricing = ->(_env) { {amount: "1.00"} }
    app = ->(_env) { [200, {}, ["OK"]] }
    middleware = Mpp::Server::Middleware.new(app, handler: handler, pricing: pricing)

    status, headers, _body = middleware.call(
      minimal_env.merge(
        "PATH_INFO" => "/paid/one",
        "QUERY_STRING" => "view=full",
        "action_dispatch.route_uri_pattern" => "/paid/:id"
      )
    )
    assert_equal 402, status

    challenge = Mpp::Challenge.from_www_authenticate(headers["WWW-Authenticate"])
    assert_equal(
      {"route" => "/paid/:id", "resource" => "/paid/one", "query" => "view=full"},
      challenge.request["_mppx_scope"]
    )
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test", "data" => "ok"}
    )

    status, headers, _body = middleware.call(
      minimal_env.merge(
        "HTTP_AUTHORIZATION" => credential.to_authorization,
        "PATH_INFO" => "/paid/two",
        "QUERY_STRING" => "view=full",
        "action_dispatch.route_uri_pattern" => "/paid/:id"
      )
    )

    assert_equal 402, status
    refute headers.key?("Payment-Receipt")
  end

  def test_normalizes_method_prefixed_sinatra_route_scope
    handler = mock_handler
    pricing = ->(_env) { {amount: "1.00"} }
    app = ->(_env) { [200, {}, ["OK"]] }
    middleware = Mpp::Server::Middleware.new(app, handler: handler, pricing: pricing)

    status, headers, _body = middleware.call(
      minimal_env.merge(
        "PATH_INFO" => "/paid/one",
        "QUERY_STRING" => "view=full",
        "sinatra.route" => "GET /paid/:id"
      )
    )

    assert_equal 402, status
    challenge = Mpp::Challenge.from_www_authenticate(headers["WWW-Authenticate"])
    assert_equal(
      {"route" => "/paid/:id", "resource" => "/paid/one", "query" => "view=full"},
      challenge.request["_mppx_scope"]
    )
  end

  def test_rejects_paid_retry_with_tampered_body_digest
    handler = mock_handler
    pricing = ->(_env) { {amount: "1.00"} }
    app = ->(_env) { [200, {}, ["OK"]] }
    middleware = Mpp::Server::Middleware.new(app, handler: handler, pricing: pricing)

    status, headers, _body = middleware.call(
      minimal_env.merge("rack.input" => StringIO.new("{\"query\":\"paid\"}"))
    )
    assert_equal 402, status

    challenge = Mpp::Challenge.from_www_authenticate(headers["WWW-Authenticate"])
    assert_equal Mpp::BodyDigest.compute("{\"query\":\"paid\"}"), challenge.digest
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test", "data" => "ok"}
    )

    status, headers, _body = middleware.call(
      minimal_env.merge(
        "HTTP_AUTHORIZATION" => credential.to_authorization,
        "rack.input" => StringIO.new("{\"query\":\"tampered\"}")
      )
    )

    assert_equal 402, status
    refute headers.key?("Payment-Receipt")
    replacement = Mpp::Challenge.from_www_authenticate(headers["WWW-Authenticate"])
    assert_equal Mpp::BodyDigest.compute("{\"query\":\"tampered\"}"), replacement.digest
  end

  def test_accepts_paid_retry_with_matching_body_digest
    handler = mock_handler
    pricing = ->(_env) { {amount: "1.00"} }
    app = lambda { |env|
      [200, {}, [env["rack.input"].read]]
    }
    middleware = Mpp::Server::Middleware.new(app, handler: handler, pricing: pricing)

    body = "{\"query\":\"paid\"}"
    status, headers, _response_body = middleware.call(
      minimal_env.merge("rack.input" => StringIO.new(body))
    )
    assert_equal 402, status

    challenge = Mpp::Challenge.from_www_authenticate(headers["WWW-Authenticate"])
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test", "data" => "ok"}
    )

    status, headers, response_body = middleware.call(
      minimal_env.merge(
        "HTTP_AUTHORIZATION" => credential.to_authorization,
        "rack.input" => StringIO.new(body)
      )
    )

    assert_equal 200, status
    assert headers.key?("Payment-Receipt")
    assert_equal [body], response_body
  end

  def test_does_not_read_request_body_when_pricing_returns_nil
    input = CountingInput.new("x" * 1024)
    app = ->(_env) { [200, {}, ["OK"]] }
    pricing = ->(_env) {}
    middleware = Mpp::Server::Middleware.new(app, handler: mock_handler, pricing: pricing)

    status, _headers, body = middleware.call(minimal_env.merge("rack.input" => input))

    assert_equal 200, status
    assert_equal ["OK"], body
    assert_equal 0, input.reads
  end

  def test_preserves_request_body_for_app_after_successful_payment
    handler = mock_handler
    pricing = ->(_env) { {amount: "1.00"} }
    seen_body = nil
    app = lambda { |env|
      seen_body = env["rack.input"].read
      [200, {}, ["OK"]]
    }
    middleware = Mpp::Server::Middleware.new(app, handler: handler, pricing: pricing)

    body = "{\"query\":\"paid\"}"

    # First request to get a challenge
    status, headers, _response_body = middleware.call(
      minimal_env.merge("rack.input" => StringIO.new(body))
    )
    assert_equal 402, status

    challenge = Mpp::Challenge.from_www_authenticate(headers["WWW-Authenticate"])
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test", "data" => "ok"}
    )

    # Second request with valid credential
    status, _headers, _response_body = middleware.call(
      minimal_env.merge(
        "HTTP_AUTHORIZATION" => credential.to_authorization,
        "rack.input" => StringIO.new(body)
      )
    )

    assert_equal 200, status
    assert_equal body, seen_body
  end

  def test_compose_handler_returns_multiple_www_authenticate
    tempo = mock_named_method("tempo", Mpp::Methods::Tempo::Defaults::PATH_USD, "0x#{"0" * 39}1")
    stripe = mock_named_method("stripe", "usd", "acct_123", decimals: 2)
    handler = Mpp::Server::MppHandler.new(
      methods: [tempo, stripe],
      realm: @realm,
      secret_key: @secret_key
    )
    composed = handler.compose(
      [tempo, {amount: "1.00"}],
      [stripe, {amount: "1.00"}]
    )
    middleware = Mpp::Server::Middleware.new(
      ->(_env) { [200, {}, ["OK"]] },
      handler: composed,
      pricing: ->(_env) { {amount: "1.00"} }
    )

    status, headers, _body = middleware.call(minimal_env)

    assert_equal 402, status
    www = Array(headers["WWW-Authenticate"])
    assert_equal 2, www.length
  end

  def test_compose_handler_binds_credentials_to_rack_scope
    tempo = mock_named_method("tempo", Mpp::Methods::Tempo::Defaults::PATH_USD, "0x#{"0" * 39}1")
    stripe = mock_named_method("stripe", "usd", "acct_123", decimals: 2)
    handler = Mpp::Server::MppHandler.new(
      methods: [tempo, stripe],
      realm: @realm,
      secret_key: @secret_key
    )
    middleware = Mpp::Server::Middleware.new(
      ->(_env) { [200, {}, ["OK"]] },
      handler: handler.compose([tempo, {amount: "1.00"}], [stripe, {amount: "1.00"}]),
      pricing: ->(_env) { {amount: "1.00"} }
    )
    scoped_env = minimal_env.merge(
      "PATH_INFO" => "/paid/one",
      "QUERY_STRING" => "view=full",
      "action_dispatch.route_uri_pattern" => "/paid/:id"
    )

    status, headers, _body = middleware.call(scoped_env)

    assert_equal 402, status
    challenge = Mpp::Challenge.from_www_authenticate(Array(headers["WWW-Authenticate"]).first)
    assert_equal(
      {"route" => "/paid/:id", "resource" => "/paid/one", "query" => "view=full"},
      challenge.request["_mppx_scope"]
    )
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test", "data" => "ok"}
    )

    status, _headers, _body = middleware.call(scoped_env.merge("HTTP_AUTHORIZATION" => credential.to_authorization))
    assert_equal 200, status

    status, _headers, _body = middleware.call(
      scoped_env.merge("HTTP_AUTHORIZATION" => credential.to_authorization, "PATH_INFO" => "/paid/two")
    )
    assert_equal 402, status
  end

  def test_varies_on_payment_signature_for_x402_success
    handler = mock_handler
    pricing = ->(_env) { {amount: "1.00"} }
    challenge = handler.charge(nil, "1.00", mppx_scope: {"resource" => "/resource"})
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test", "data" => "ok"}
    )
    app = ->(_env) { [200, {}, ["OK"]] }
    middleware = Mpp::Server::Middleware.new(app, handler: handler, pricing: pricing)

    _status, headers, _body = middleware.call(
      minimal_env.merge(
        "HTTP_AUTHORIZATION" => credential.to_authorization,
        "HTTP_PAYMENT_SIGNATURE" => "placeholder"
      )
    )

    vary_fields = headers.fetch("Vary", "").split(",").map { |field| field.strip.downcase }
    assert_includes vary_fields, "authorization"
    assert_includes vary_fields, "payment-signature"
  end

  def test_requires_auth_reads_payment_authorization_and_preserves_bearer
    handler = mock_handler(requires_auth: true)
    pricing = ->(_env) { {amount: "1.00"} }
    challenge = handler.charge("Bearer app-token", "1.00", mppx_scope: {"resource" => "/resource"})
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test", "data" => "ok"}
    )
    app = ->(_env) { [200, {}, ["OK"]] }
    middleware = Mpp::Server::Middleware.new(app, handler: handler, pricing: pricing)

    status, headers, body = middleware.call(
      minimal_env.merge(
        "HTTP_AUTHORIZATION" => "Bearer app-token",
        "HTTP_PAYMENT_AUTHORIZATION" => credential.to_authorization
      )
    )

    assert_equal 200, status
    assert headers.key?("Payment-Receipt")
    assert_equal ["OK"], body
    vary_fields = headers.fetch("Vary", "").split(",").map { |field| field.strip.downcase }
    assert_includes vary_fields, "payment-authorization"
  end

  def test_requires_auth_challenge_advertises_payment_authorization_header
    handler = mock_handler(requires_auth: true)
    pricing = ->(_env) { {amount: "1.00"} }
    middleware = Mpp::Server::Middleware.new(->(_env) { [200, {}, ["OK"]] }, handler: handler, pricing: pricing)

    status, headers, _body = middleware.call(
      minimal_env.merge("HTTP_AUTHORIZATION" => "Bearer app-token")
    )

    assert_equal 402, status
    challenge = Mpp::Challenge.from_www_authenticate(headers["WWW-Authenticate"])
    assert_equal Mpp::PAYMENT_AUTHORIZATION_HEADER, challenge.header
    assert_includes headers["WWW-Authenticate"], %(header="#{Mpp::PAYMENT_AUTHORIZATION_HEADER}")
  end

  def minimal_env
    {
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/resource"
    }
  end

  def assert_vary_authorization(headers)
    vary_fields = headers.fetch("Vary", "").split(",").map do |field|
      field.strip.downcase
    end
    assert_includes vary_fields, "authorization"
  end

  def call_paid(app, handler: mock_handler)
    pricing = ->(_env) { {amount: "1.00"} }
    challenge = handler.charge(nil, "1.00", mppx_scope: {"resource" => "/resource"})
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "test", "data" => "ok"}
    )
    middleware = Mpp::Server::Middleware.new(app, handler: handler, pricing: pricing)
    middleware.call(minimal_env.merge("HTTP_AUTHORIZATION" => credential.to_authorization))
  end

  def mock_handler(requires_auth: false)
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
      secret_key: @secret_key,
      requires_auth: requires_auth
    )
  end

  def mock_named_method(name, currency, recipient, decimals: 6)
    verify_fn = lambda { |credential, _request|
      Mpp::Receipt.success("ref-#{credential.challenge.id[0..7]}", method: name)
    }
    intent = Mpp::Server::FunctionalIntent.new("charge", &verify_fn)
    stub_method = Object.new
    stub_method.define_singleton_method(:name) { name }
    stub_method.define_singleton_method(:intents) { {"charge" => intent} }
    stub_method.define_singleton_method(:currency) { currency }
    stub_method.define_singleton_method(:recipient) { recipient }
    stub_method.define_singleton_method(:decimals) { decimals }
    stub_method
  end

  class NonRewindableInput
    def initialize(body)
      @input = StringIO.new(body)
    end

    def read(*args)
      @input.read(*args)
    end
  end

  class CountingInput
    attr_reader :reads

    def initialize(body)
      @input = StringIO.new(body)
      @reads = 0
    end

    def read(*args)
      @reads += 1
      @input.read(*args)
    end
  end
end
