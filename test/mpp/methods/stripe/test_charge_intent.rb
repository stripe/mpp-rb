# typed: ignore
# frozen_string_literal: true

require "test_helper"
require "json"

class TestStripeChargeIntent < Minitest::Test
  def setup
    @intent = Mpp::Methods::Stripe::ChargeIntent.new(
      secret_key: "sk_test_fake",
      api_base: "https://api.stripe.com"
    )

    @stripe_available = begin
      require "stripe"
      true
    rescue LoadError
      false
    end
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

  def make_request(amount: "100", currency: "usd", method_details: nil)
    req = {
      "amount" => amount,
      "currency" => currency,
      "recipient" => "acct_test123"
    }
    req["methodDetails"] = method_details if method_details
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
    skip "stripe gem not available" unless @stripe_available

    credential = make_credential(payload: {"spt" => "spt_test123", "externalId" => "ext_1"})
    request = make_request(method_details: {"metadata" => {"order" => "123"}})

    mock_result = Struct.new(:id, :status).new("pi_abc123", "succeeded")
    mock_pi = Minitest::Mock.new
    mock_pi.expect(:create, mock_result, [Hash])

    mock_v1 = Struct.new(:payment_intents).new(mock_pi)
    mock_client = Struct.new(:v1).new(mock_v1)

    ::Stripe::StripeClient.stub(:new, mock_client) do
      receipt = @intent.verify(credential, request)
      assert_equal "success", receipt.status
      assert_equal "pi_abc123", receipt.reference
      assert_equal "stripe", receipt.method
      assert_equal "ext_1", receipt.external_id
    end

    mock_pi.verify
  end

  def test_verify_rejects_failed_payment
    skip "stripe gem not available" unless @stripe_available

    credential = make_credential(payload: {"spt" => "spt_test123"})
    request = make_request

    error = ::Stripe::StripeError.new("Card declined")

    mock_pi = Minitest::Mock.new
    mock_pi.expect(:create, nil) { raise error }

    mock_v1 = Struct.new(:payment_intents).new(mock_pi)
    mock_client = Struct.new(:v1).new(mock_v1)

    ::Stripe::StripeClient.stub(:new, mock_client) do
      err = assert_raises(Mpp::VerificationError) do
        @intent.verify(credential, request)
      end
      assert_match(/Card declined/, err.message)
    end
  end

  def test_verify_rejects_replayed_payment
    skip "stripe gem not available" unless @stripe_available

    credential = make_credential(payload: {"spt" => "spt_test123"})
    request = make_request

    mock_headers = {"idempotent-replayed" => "true"}
    mock_last_response = Struct.new(:headers).new(mock_headers)
    mock_result = Struct.new(:id, :status, :last_response).new("pi_abc123", "succeeded", mock_last_response)
    mock_pi = Minitest::Mock.new
    mock_pi.expect(:create, mock_result, [Hash])

    mock_v1 = Struct.new(:payment_intents).new(mock_pi)
    mock_client = Struct.new(:v1).new(mock_v1)

    ::Stripe::StripeClient.stub(:new, mock_client) do
      err = assert_raises(Mpp::VerificationError) do
        @intent.verify(credential, request)
      end
      assert_equal "Payment has already been processed.", err.message
    end
  end

  def test_verify_rejects_requires_action
    skip "stripe gem not available" unless @stripe_available

    credential = make_credential(payload: {"spt" => "spt_test123"})
    request = make_request

    mock_result = Struct.new(:id, :status).new("pi_needs3ds", "requires_action")
    mock_pi = Minitest::Mock.new
    mock_pi.expect(:create, mock_result, [Hash])

    mock_v1 = Struct.new(:payment_intents).new(mock_pi)
    mock_client = Struct.new(:v1).new(mock_v1)

    ::Stripe::StripeClient.stub(:new, mock_client) do
      assert_raises(Mpp::PaymentActionRequiredError) do
        @intent.verify(credential, request)
      end
    end
  end
end
