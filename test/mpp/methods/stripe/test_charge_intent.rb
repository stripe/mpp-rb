# typed: ignore
# frozen_string_literal: true

require "test_helper"
require "json"
require "tmpdir"

class TestStripeChargeIntent < Minitest::Test
  FakePaymentIntents = Struct.new(:result, :error, :assertion, :calls, keyword_init: true) do
    def initialize(result: nil, error: nil, assertion: nil)
      super(result: result, error: error, assertion: assertion, calls: [])
    end

    def create(params, opts)
      calls << [params, opts]
      assertion&.call(params, opts)
      raise error if error

      result
    end
  end

  def setup
    @intent = Mpp::Methods::Stripe::ChargeIntent.new(
      secret_key: "sk_test_fake",
      api_base: "https://api.stripe.com"
    )
  end

  def intent_with_payment_intents(payment_intents)
    client = Struct.new(:v1).new(Struct.new(:payment_intents).new(payment_intents))
    Mpp::Methods::Stripe::ChargeIntent.new(secret_key: "sk_test_fake", client: client)
  end

  def with_fake_stripe_client(payment_intents)
    created_secret_keys = []
    previous_stripe = nil
    previous_stripe = Object.const_get(:Stripe) if Object.const_defined?(:Stripe, false)
    Object.send(:remove_const, :Stripe) if Object.const_defined?(:Stripe, false)

    fake_client = Class.new do
      define_method(:initialize) do |secret_key|
        created_secret_keys << secret_key
      end

      define_method(:v1) do
        Struct.new(:payment_intents).new(payment_intents)
      end
    end

    fake_stripe = Module.new
    fake_stripe.const_set(:StripeClient, fake_client)
    Object.const_set(:Stripe, fake_stripe)

    Dir.mktmpdir do |dir|
      fake_stripe_path = File.join(dir, "stripe.rb")
      File.write(fake_stripe_path, "# fake stripe for tests\n")
      $LOAD_PATH.unshift(dir)
      begin
        yield created_secret_keys
      ensure
        $LOAD_PATH.delete(dir)
        $LOADED_FEATURES.delete(fake_stripe_path)
      end
    end
  ensure
    Object.send(:remove_const, :Stripe) if Object.const_defined?(:Stripe, false)
    Object.const_set(:Stripe, previous_stripe) if previous_stripe
  end

  def make_credential(payload:, expires: nil)
    expires ||= (Time.now.utc + 300).strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    echo = Mpp::ChallengeEcho.new(
      id: "test-id",
      realm: "test-realm",
      method: "stripe",
      intent: "charge",
      request: "",
      expires: expires,
      digest: nil,
      opaque: nil
    )
    Mpp::Credential.new(challenge: echo, payload: payload)
  end

  def make_request(amount: "100", currency: "usd", payment_method_types: ["card"], method_details: nil, external_id: nil)
    req = {
      "amount" => amount,
      "currency" => currency,
      "recipient" => "acct_test123"
    }
    req["externalId"] = external_id if external_id
    details = {}
    details["paymentMethodTypes"] = payment_method_types unless payment_method_types.nil?
    details.merge!(method_details) if method_details
    req["methodDetails"] = details unless details.empty?
    req
  end

  def test_verify_rejects_missing_spt
    credential = make_credential(payload: {"type" => "token"})
    request = make_request

    assert_raises(Mpp::VerificationError) do
      @intent.verify(credential, request)
    end
  end

  def test_verify_rejects_expired_challenge
    expired = (Time.now.utc - 60).strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    credential = make_credential(
      payload: {"spt" => "spt_test123"},
      expires: expired
    )
    request = make_request

    err = assert_raises(Mpp::VerificationError) do
      @intent.verify(credential, request)
    end
    assert_match(/expired/i, err.message)
  end

  def test_verify_calls_stripe_sdk
    credential = make_credential(payload: {"spt" => "spt_test123", "externalId" => "ext_1"})
    request = make_request(
      payment_method_types: ["card", "link"],
      method_details: {"metadata" => {"order" => "123"}},
      external_id: "ext_1"
    )

    mock_result = Struct.new(:id, :status).new("pi_abc123", "succeeded")
    payment_intents = FakePaymentIntents.new(result: mock_result, assertion: ->(params, opts) do
      assert_equal 100, params[:amount]
      assert_equal "usd", params[:currency]
      assert_equal "spt_test123", params[:shared_payment_granted_token]
      assert_equal true, params[:confirm]
      assert_equal ["card", "link"], params[:payment_method_types]
      refute params.key?(:automatic_payment_methods)
      assert_equal({"machine_payment" => "true", "order" => "123"}, params[:metadata])
      assert_equal "mpp_test-id_spt_test123", opts[:idempotency_key]
      assert_equal Mpp::Methods::Stripe::Defaults::MACHINE_PAYMENTS_API_VERSION, opts[:stripe_version]
    end)

    receipt = intent_with_payment_intents(payment_intents).verify(credential, request)
    assert_equal "success", receipt.status
    assert_equal "pi_abc123", receipt.reference
    assert_equal "stripe", receipt.method
    assert_equal "ext_1", receipt.external_id
    assert_equal 1, payment_intents.calls.length
  end

  def test_verify_constructs_stripe_client_when_not_injected
    credential = make_credential(payload: {"spt" => "spt_test123", "externalId" => "ext_1"})
    request = make_request(
      payment_method_types: ["card"],
      external_id: "ext_1"
    )

    mock_result = Struct.new(:id, :status).new("pi_abc123", "succeeded")
    payment_intents = FakePaymentIntents.new(result: mock_result)

    with_fake_stripe_client(payment_intents) do |created_secret_keys|
      receipt = @intent.verify(credential, request)

      assert_equal ["sk_test_fake"], created_secret_keys
      assert_equal "pi_abc123", receipt.reference
      assert_equal "ext_1", receipt.external_id
      assert_equal 1, payment_intents.calls.length
    end
  end

  def test_verify_rejects_forged_external_id
    credential = make_credential(payload: {"spt" => "spt_test123", "externalId" => "attacker-order-999"})
    request = make_request(external_id: "server-order-123")

    err = assert_raises(Mpp::InvalidChallengeError) do
      @intent.verify(credential, request)
    end
    assert_match(/externalId/, err.message)
  end

  def test_verify_ignores_payload_only_external_id
    credential = make_credential(payload: {"spt" => "spt_test123", "externalId" => "attacker-order-999"})
    request = make_request

    mock_result = Struct.new(:id, :status).new("pi_abc123", "succeeded")
    payment_intents = FakePaymentIntents.new(result: mock_result)

    receipt = intent_with_payment_intents(payment_intents).verify(credential, request)
    assert_nil receipt.external_id
    assert_equal 1, payment_intents.calls.length
  end

  def test_verify_rejects_missing_payment_method_types
    credential = make_credential(payload: {"spt" => "spt_test123"})
    request = make_request(payment_method_types: nil)

    err = assert_raises(Mpp::VerificationError) do
      @intent.verify(credential, request)
    end
    assert_match(/paymentMethodTypes/, err.message)
  end

  def test_verify_rejects_empty_payment_method_types
    credential = make_credential(payload: {"spt" => "spt_test123"})
    request = make_request(payment_method_types: [])

    err = assert_raises(Mpp::VerificationError) do
      @intent.verify(credential, request)
    end
    assert_match(/paymentMethodTypes/, err.message)
  end

  def test_verify_rejects_failed_payment
    credential = make_credential(payload: {"spt" => "spt_test123"})
    request = make_request

    error = StandardError.new("Card declined")
    payment_intents = FakePaymentIntents.new(error: error)

    err = assert_raises(Mpp::VerificationError) do
      intent_with_payment_intents(payment_intents).verify(credential, request)
    end
    assert_match(/Card declined/, err.message)
  end

  def test_verify_scopes_idempotency_key_to_spt
    request = make_request
    mock_result = Struct.new(:id, :status).new("pi_abc123", "succeeded")
    payment_intents = FakePaymentIntents.new(result: mock_result)
    intent = intent_with_payment_intents(payment_intents)

    intent.verify(make_credential(payload: {"spt" => "spt_first"}), request)
    intent.verify(make_credential(payload: {"spt" => "spt_second"}), request)

    keys = payment_intents.calls.map { |(_params, opts)| opts[:idempotency_key] }
    assert_equal ["mpp_test-id_spt_first", "mpp_test-id_spt_second"], keys
  end

  def test_verify_rejects_replayed_payment
    credential = make_credential(payload: {"spt" => "spt_test123"})
    request = make_request

    [:http_headers, :headers].each do |accessor|
      response = Struct.new(accessor).new({"idempotent-replayed" => "true"})
      result = Struct.new(:id, :status, :last_response).new("pi_abc123", "succeeded", response)
      payment_intents = FakePaymentIntents.new(result: result)

      error = assert_raises(Mpp::VerificationError) do
        intent_with_payment_intents(payment_intents).verify(credential, request)
      end
      assert_equal "Payment has already been processed.", error.message
    end
  end

  def test_verify_rejects_requires_action
    credential = make_credential(payload: {"spt" => "spt_test123"})
    request = make_request

    mock_result = Struct.new(:id, :status).new("pi_needs3ds", "requires_action")
    payment_intents = FakePaymentIntents.new(result: mock_result)

    assert_raises(Mpp::PaymentActionRequiredError) do
      intent_with_payment_intents(payment_intents).verify(credential, request)
    end
  end
end
