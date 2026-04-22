# frozen_string_literal: true

require "test_helper"

class TestStripeMethod < Minitest::Test
  def setup
    @method = Mpp::Methods::Stripe::StripeMethod.new(
      secret_key: "sk_test_fake",
      network_id: "acct_test123",
      payment_methods: ["card"],
      metadata: {"app" => "myapp"}
    )
  end

  def test_name_is_stripe
    assert_equal "stripe", @method.name
  end

  def test_currency_defaults_to_usd
    assert_equal "usd", @method.currency
  end

  def test_decimals_defaults_to_2
    assert_equal 2, @method.decimals
  end

  def test_recipient_is_network_id
    assert_equal "acct_test123", @method.recipient
  end

  def test_transform_request_injects_method_details
    request = {"amount" => "100", "currency" => "usd", "recipient" => "acct_test123"}
    result = @method.transform_request(request, nil)

    assert_equal "acct_test123", result["methodDetails"]["networkId"]
    assert_equal ["card"], result["methodDetails"]["paymentMethods"]
    assert_equal({"app" => "myapp"}, result["methodDetails"]["metadata"])
  end

  def test_transform_request_preserves_existing_method_details
    request = {
      "amount" => "100",
      "currency" => "usd",
      "recipient" => "acct_test123",
      "methodDetails" => {"existing" => "value"}
    }
    result = @method.transform_request(request, nil)

    assert_equal "acct_test123", result["methodDetails"]["networkId"]
    assert_equal "value", result["methodDetails"]["existing"]
  end

  def test_transform_request_omits_nil_payment_methods
    method = Mpp::Methods::Stripe::StripeMethod.new(
      secret_key: "sk_test_fake",
      network_id: "acct_test123"
    )
    result = method.transform_request({"amount" => "100"}, nil)

    assert_equal "acct_test123", result["methodDetails"]["networkId"]
    refute result["methodDetails"].key?("paymentMethods")
    refute result["methodDetails"].key?("metadata")
  end

  def test_factory_creates_method_with_charge_intent
    method = Mpp::Methods::Stripe.stripe(
      secret_key: "sk_test_fake",
      network_id: "acct_test123"
    )

    assert_equal "stripe", method.name
    assert_equal "usd", method.currency
    assert_equal "acct_test123", method.recipient
    assert_equal 2, method.decimals
    assert method.intents.key?("charge")
    assert_instance_of Mpp::Methods::Stripe::ChargeIntent, method.intents["charge"]
  end

  def test_integration_challenge_round_trip
    method = Mpp::Methods::Stripe.stripe(
      secret_key: "sk_test_fake",
      network_id: "acct_test123",
      payment_methods: ["card"],
      metadata: {"order" => "abc"}
    )

    handler = Mpp::Server::MppHandler.new(
      method: method,
      realm: "test-realm",
      secret_key: "test-secret"
    )

    result = handler.charge(nil, "1.00")
    assert_instance_of Mpp::Challenge, result
    assert_equal "stripe", result.method
    assert_equal "charge", result.intent

    request = result.request
    assert_equal "100", request["amount"]
    assert_equal "usd", request["currency"]
    assert_equal "acct_test123", request["recipient"]
    assert_equal "acct_test123", request["methodDetails"]["networkId"]
    assert_equal ["card"], request["methodDetails"]["paymentMethods"]
    assert_equal({"order" => "abc"}, request["methodDetails"]["metadata"])
  end
end
