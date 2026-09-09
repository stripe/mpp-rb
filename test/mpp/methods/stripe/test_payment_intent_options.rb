# frozen_string_literal: true

require "test_helper"

class TestPaymentIntentOptions < Minitest::Test
  TEMPO_ADDRESS = "0x#{"1" * 40}"

  class FakePaymentIntents
    attr_reader :calls
    attr_accessor :results

    def initialize(&on_create)
      @calls = []
      @results = []
      @on_create = on_create
    end

    def create(params, options)
      calls << [params, options]
      @on_create&.call
      result = results.shift
      raise result if result.is_a?(Exception)

      result || Struct.new(:id, :status).new("pi_123", "succeeded")
    end
  end

  class FakeStripeClient
    attr_reader :payment_intents

    def initialize(&on_create)
      @payment_intents = FakePaymentIntents.new(&on_create)
    end

    def v1
      Struct.new(:payment_intents).new(payment_intents)
    end
  end

  class FakeCryptoIntent
    attr_reader :name, :broadcasts

    def initialize(order = nil)
      @name = "charge"
      @broadcasts = 0
      @order = order
    end

    def verify(credential, _request)
      raise Mpp::VerificationError, "invalid crypto credential" unless credential.payload["valid"]

      yield if block_given?
      @order << :broadcast if @order
      @broadcasts += 1
      Mpp::Receipt.success("0xtx", method: "tempo")
    end
  end

  def test_validation_matches_the_javascript_shape
    options = Mpp::Methods::Stripe::PaymentIntentOptions.validate({
      amount: 999,
      confirm: false,
      customer: "cus_123",
      currency: "eur",
      hooks: {inputs: {tax: {calculation: "taxcalc_123"}}},
      metadata: {order_id: "order_123"},
      receipt_email: "buyer@example.com"
    })

    assert_equal({
      customer: "cus_123",
      hooks: {inputs: {tax: {calculation: "taxcalc_123"}}},
      metadata: {"order_id" => "order_123"},
      receipt_email: "buyer@example.com"
    }, options)
    [:customer, :receipt_email].each do |field|
      assert_raises(ArgumentError) { Mpp::Methods::Stripe::PaymentIntentOptions.validate({field => ""}) }
    end
    assert_raises(ArgumentError) do
      Mpp::Methods::Stripe::PaymentIntentOptions.validate(hooks: {inputs: {tax: {calculation: ""}}})
    end
  end

  def test_static_options_are_private_and_reach_spt_payment_intent
    client = FakeStripeClient.new
    method = machine_payments(client: client, metadata: {"configured" => "yes"}).spt.charge
    server = server_for(method)
    options = full_options.merge(amount: 999, currency: "eur", confirm: false)

    challenge = server.charge(nil, "0.50", payment_intent_options: options)
    refute challenge.request.key?("payment_intent_options")
    refute challenge.request.key?("paymentIntentOptions")

    credential = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"spt" => "spt_123"})
    server.charge(credential.to_authorization, "0.50", payment_intent_options: options)

    params, request_options = client.payment_intents.calls.fetch(0)
    assert_equal 50, params[:amount]
    assert_equal "usd", params[:currency]
    assert_equal true, params[:confirm]
    assert_equal "cus_123", params[:customer]
    assert_equal "buyer@example.com", params[:receipt_email]
    assert_equal({inputs: {tax: {calculation: "taxcalc_123"}}}, params[:hooks])
    assert_equal "custom", params[:metadata]["machine_payment"]
    assert_equal "mpp-rb/#{Mpp::VERSION}", params[:metadata]["mpp_sdk"]
    assert_equal challenge.id, params[:metadata]["mpp_challenge_id"]
    assert_equal "charge", params[:metadata]["mpp_intent"]
    assert_equal "yes", params[:metadata]["configured"]
    assert_equal "order_123", params[:metadata]["order_id"]
    assert_equal "mpp_#{challenge.id}_spt_123", request_options[:idempotency_key]
  end

  def test_deferred_spt_options_only_run_after_valid_credential
    client = FakeStripeClient.new
    method = machine_payments(client: client).spt.charge
    server = server_for(method)
    calls = []
    resolver = lambda do |challenge:, credential:, request:|
      calls << [challenge, credential, request]
      {customer: "cus_123"}
    end

    challenge = server.charge(nil, "0.50", payment_intent_options: resolver)
    assert_empty calls
    server.charge("Payment malformed", "0.50", payment_intent_options: resolver)
    assert_empty calls

    forged_echo = Mpp::ChallengeEcho.new(**challenge.to_echo.to_h.merge(id: "forged"))
    forged = Mpp::Credential.new(challenge: forged_echo, payload: {"spt" => "spt_123"})
    server.charge(forged.to_authorization, "0.50", payment_intent_options: resolver)
    assert_empty calls

    invalid = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"not_spt" => true})
    assert_raises(Mpp::VerificationError) do
      server.charge(invalid.to_authorization, "0.50", payment_intent_options: resolver)
    end
    assert_empty calls

    expired_at = (Time.now.utc - 60).strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    expired_challenge = server.charge(nil, "0.50", payment_intent_options: resolver, expires: expired_at)
    expired = Mpp::Credential.new(challenge: expired_challenge.to_echo, payload: {"spt" => "spt_expired"})
    server.charge(
      expired.to_authorization,
      "0.50",
      payment_intent_options: resolver,
      expires: expired_at
    )
    assert_empty calls

    valid = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"spt" => "spt_123"})
    server.charge(valid.to_authorization, "0.50", payment_intent_options: resolver)
    assert_equal 1, calls.length
    resolved_challenge, resolved_credential, resolved_request = calls.first
    assert_instance_of Mpp::Challenge, resolved_challenge
    assert_equal valid, resolved_credential
    assert_equal challenge.request, resolved_request
    assert_equal challenge.request, resolved_challenge.request
  end

  def test_spt_resolver_bad_request_prevents_payment_intent_creation
    client = FakeStripeClient.new
    method = machine_payments(client: client).spt.charge
    server = server_for(method)
    resolver = ->(**) { raise Mpp::BadRequestError.new(reason: "invalid tax location") }
    challenge = server.charge(nil, "0.50", payment_intent_options: resolver)
    credential = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"spt" => "spt_123"})

    assert_raises(Mpp::BadRequestError) do
      server.charge(credential.to_authorization, "0.50", payment_intent_options: resolver)
    end
    assert_empty client.payment_intents.calls
  end

  def test_crypto_resolves_before_broadcast_and_records_options
    order = []
    client = FakeStripeClient.new { order << :payment_intent }
    method = machine_payments(client: client, metadata: {"configured" => "yes"}, tempo: true).tempo.charge
    intent = FakeCryptoIntent.new(order)
    method.intents["charge"] = intent
    server = server_for(method)
    resolver = lambda do |challenge:, credential:, request:|
      order << :resolve
      assert_equal "tempo", challenge.method
      assert credential.payload["valid"]
      assert_equal challenge.request, request
      full_options
    end

    challenge = server.charge(nil, "0.01", payment_intent_options: resolver)
    assert_empty order
    invalid = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"valid" => false})
    assert_raises(Mpp::VerificationError) do
      server.charge(invalid.to_authorization, "0.01", payment_intent_options: resolver)
    end
    assert_empty order

    valid = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"valid" => true})
    server.charge(valid.to_authorization, "0.01", payment_intent_options: resolver)
    assert_equal [:resolve, :broadcast, :payment_intent], order
    assert_equal 1, intent.broadcasts
    params, = client.payment_intents.calls.fetch(0)
    assert_equal "cus_123", params[:customer]
    assert_equal "buyer@example.com", params[:receipt_email]
    assert_equal "order_123", params[:metadata]["order_id"]
    assert_equal "yes", params[:metadata]["configured"]
    assert_equal challenge.id, params[:metadata]["mpp_challenge_id"]
  end

  def test_crypto_resolver_failure_prevents_broadcast
    client = FakeStripeClient.new
    method = machine_payments(client: client, tempo: true).tempo.charge
    intent = FakeCryptoIntent.new
    method.intents["charge"] = intent
    server = server_for(method)
    resolver = ->(**) { raise Mpp::BadRequestError.new(reason: "invalid tax location") }
    challenge = server.charge(nil, "0.01", payment_intent_options: resolver)
    credential = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"valid" => true})

    assert_raises(Mpp::BadRequestError) do
      server.charge(credential.to_authorization, "0.01", payment_intent_options: resolver)
    end
    assert_equal 0, intent.broadcasts
    assert_empty client.payment_intents.calls
  end

  def test_crypto_recording_falls_back_only_for_definitive_invalid_requests
    definitive = Class.new(StandardError) { def type = "StripeInvalidRequestError" }.new("invalid customer")
    client = FakeStripeClient.new
    client.payment_intents.results = [definitive, Struct.new(:id, :status).new("pi_fallback", "succeeded")]
    recorder(client).call(recorder_payload(payment_intent_options: full_options, has_payment_intent_options: true))

    assert_equal 2, client.payment_intents.calls.length
    fallback_params, fallback_options = client.payment_intents.calls.fetch(1)
    refute fallback_params.key?(:customer)
    refute fallback_params.key?(:hooks)
    refute fallback_params.key?(:receipt_email)
    assert_equal %w[machine_payment mpp_challenge_id mpp_intent mpp_sdk], fallback_params[:metadata].keys.sort
    assert_equal "0xtx_fallback", fallback_options[:idempotency_key]

    ambiguous_client = FakeStripeClient.new
    ambiguous_client.payment_intents.results = [StandardError.new("connection reset")]
    recorder(ambiguous_client).call(recorder_payload(payment_intent_options: full_options, has_payment_intent_options: true))
    assert_equal 1, ambiguous_client.payment_intents.calls.length
  end

  def test_analytics_metadata_limits_generated_values_to_500_characters
    challenge = Struct.new(:id, :intent).new("i" * 501, "😀" * 501)
    metadata = Mpp::Methods::Stripe::AnalyticsMetadata.build(challenge)

    assert_equal 500, metadata["mpp_challenge_id"].length
    assert_equal 500, metadata["mpp_intent"].each_char.count
  end

  private

  def full_options
    {
      customer: "cus_123",
      hooks: {inputs: {tax: {calculation: "taxcalc_123"}}},
      metadata: {machine_payment: "custom", order_id: "order_123"},
      receipt_email: "buyer@example.com"
    }
  end

  def machine_payments(client:, metadata: nil, tempo: false)
    Mpp::Methods::Stripe.create(
      network_id: "network_123",
      livemode: false,
      client: client,
      deposit_addresses: tempo ? {tempo: TEMPO_ADDRESS} : nil,
      metadata: metadata
    )
  end

  def server_for(method)
    Mpp.create(method: method, realm: "api.example.com", secret_key: "secret")
  end

  def recorder(client)
    Mpp::Methods::Stripe::CryptoPaymentRecorder.new(client: client, network: "tempo")
  end

  def recorder_payload(**options)
    challenge = Mpp::Challenge.new(
      id: "challenge_123",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "10000"},
      realm: "api.example.com"
    )
    {
      challenge: challenge,
      receipt: Mpp::Receipt.success("0xtx", method: "tempo"),
      request: challenge.request,
      **options
    }
  end
end
