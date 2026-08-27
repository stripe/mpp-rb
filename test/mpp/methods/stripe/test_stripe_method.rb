# frozen_string_literal: true

require "test_helper"

class TestStripeMethod < Minitest::Test
  def setup
    @method = Mpp::Methods::Stripe::StripeMethod.new(
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
    assert_equal ["card"], result["methodDetails"]["paymentMethodTypes"]
    refute result["methodDetails"].key?("paymentMethods")
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

  def test_requires_payment_methods_allowlist
    assert_raises(ArgumentError) do
      Mpp::Methods::Stripe::StripeMethod.new(
        network_id: "acct_test123"
      )
    end
  end

  def test_rejects_empty_payment_methods_allowlist
    assert_raises(ArgumentError) do
      Mpp::Methods::Stripe::StripeMethod.new(
        network_id: "acct_test123",
        payment_methods: []
      )
    end
  end

  def test_transform_request_omits_nil_metadata
    method = Mpp::Methods::Stripe::StripeMethod.new(
      network_id: "acct_test123",
      payment_methods: ["card"]
    )
    result = method.transform_request({"amount" => "100"}, nil)

    assert_equal "acct_test123", result["methodDetails"]["networkId"]
    assert_equal ["card"], result["methodDetails"]["paymentMethodTypes"]
    refute result["methodDetails"].key?("metadata")
  end

  def test_transform_request_binds_configured_external_id
    method = Mpp::Methods::Stripe::StripeMethod.new(
      network_id: "acct_test123",
      payment_methods: ["card"],
      external_id: "order-123"
    )
    result = method.transform_request({"amount" => "100"}, nil)

    assert_equal "order-123", result["externalId"]
  end

  def test_transform_request_preserves_route_external_id
    method = Mpp::Methods::Stripe::StripeMethod.new(
      network_id: "acct_test123",
      payment_methods: ["card"],
      external_id: "configured-order"
    )
    result = method.transform_request({"amount" => "100", "externalId" => "route-order"}, nil)

    assert_equal "route-order", result["externalId"]
  end

  def test_factory_creates_method_with_charge_intent
    method = Mpp::Methods::Stripe.stripe(
      secret_key: "sk_test_fake",
      network_id: "acct_test123",
      payment_methods: ["card"]
    )

    assert_equal "stripe", method.name
    assert_equal "usd", method.currency
    assert_equal "acct_test123", method.recipient
    assert_equal 2, method.decimals
    assert method.intents.key?("charge")
    assert_instance_of Mpp::Methods::Stripe::ChargeIntent, method.intents["charge"]
  end

  def test_factory_exposes_payment_success_hook
    hook = ->(_payload) {}
    method = Mpp::Methods::Stripe.stripe(
      secret_key: "sk_test_fake",
      network_id: "acct_test123",
      payment_methods: ["card"],
      on_payment_success: hook
    )

    assert_same hook, method.on_payment_success
  end

  def test_rejects_non_callable_payment_success_hook
    [false, "not callable"].each do |hook|
      error = assert_raises(ArgumentError) do
        Mpp::Methods::Stripe::StripeMethod.new(
          network_id: "acct_test123",
          payment_methods: ["card"],
          on_payment_success: hook
        )
      end

      assert_equal "on_payment_success must be callable", error.message
    end
  end

  def test_factory_exposes_offer_availability_hook
    seen = []
    method = Mpp::Methods::Stripe.stripe(
      secret_key: "sk_test_fake",
      network_id: "acct_test123",
      payment_methods: ["card"],
      can_offer: lambda { |request|
        seen << request
        false
      }
    )

    refute method.can_offer?({"amount" => "50"})
    assert_equal [{"amount" => "50"}], seen
    assert @method.can_offer?({"amount" => "50"})
  end

  def test_rejects_non_callable_offer_availability_hook
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Stripe::StripeMethod.new(
        network_id: "acct_test123",
        payment_methods: ["card"],
        can_offer: Object.new
      )
    end

    assert_equal "can_offer must be callable", error.message
  end

  def test_client_method_echoes_request_bound_external_id
    method = Mpp::Methods::Stripe::ClientMethod.new(
      create_spt: ->(**_params) { "spt_test123" },
      payment_method: "pm_card_visa"
    )
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "test-realm",
      method: "stripe",
      intent: "charge",
      request: {
        "amount" => "100",
        "currency" => "usd",
        "externalId" => "server-order-123",
        "methodDetails" => {"networkId" => "acct_test123", "paymentMethodTypes" => ["card"]}
      }
    )

    credential = method.create_credential(challenge)

    assert_equal "spt_test123", credential.payload["spt"]
    assert_equal "server-order-123", credential.payload["externalId"]
  end

  def test_client_method_request_external_id_overrides_local_external_id
    method = Mpp::Methods::Stripe::ClientMethod.new(
      create_spt: ->(**_params) { "spt_test123" },
      external_id: "client-order-999",
      payment_method: "pm_card_visa"
    )
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "test-realm",
      method: "stripe",
      intent: "charge",
      request: {
        "amount" => "100",
        "currency" => "usd",
        "externalId" => "server-order-123",
        "methodDetails" => {"networkId" => "acct_test123", "paymentMethodTypes" => ["card"]}
      }
    )

    credential = method.create_credential(challenge)

    assert_equal "server-order-123", credential.payload["externalId"]
  end

  def test_client_method_rejects_local_external_id_without_request_binding
    method = Mpp::Methods::Stripe::ClientMethod.new(
      create_spt: ->(**_params) { "spt_test123" },
      external_id: "client-order-999",
      payment_method: "pm_card_visa"
    )
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "test-realm",
      method: "stripe",
      intent: "charge",
      request: {
        "amount" => "100",
        "currency" => "usd",
        "methodDetails" => {"networkId" => "acct_test123", "paymentMethodTypes" => ["card"]}
      }
    )

    err = assert_raises(ArgumentError) do
      method.create_credential(challenge)
    end
    assert_match(/external_id must be bound/, err.message)
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
    assert_equal ["card"], request["methodDetails"]["paymentMethodTypes"]
    assert_equal({"order" => "abc"}, request["methodDetails"]["metadata"])
  end

  def test_factory_creates_method_with_settle
    settle = ->(**_params) { {id: "pi_custom", status: "succeeded"} }
    method = Mpp::Methods::Stripe.stripe(
      network_id: "acct_machine_payments",
      payment_methods: ["card", "link"],
      settle: settle
    )

    assert_equal "stripe", method.name
    assert_equal "acct_machine_payments", method.recipient
    assert method.intents.key?("charge")
    assert_instance_of Mpp::Methods::Stripe::ChargeIntent, method.intents["charge"]
  end

  def test_factory_rejects_secret_key_and_settle
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Stripe.stripe(
        secret_key: "sk_test_fake",
        network_id: "acct_test123",
        payment_methods: ["card"],
        settle: ->(**_params) { {id: "pi_x", status: "succeeded"} }
      )
    end
    assert_equal "pass settle or secret_key, not both", error.message
  end

  def test_factory_requires_secret_key_or_settle
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Stripe.stripe(
        network_id: "acct_test123",
        payment_methods: ["card"]
      )
    end
    assert_equal "secret_key or settle is required", error.message
  end
end
