# frozen_string_literal: true

require "test_helper"
require "json"
require_relative "../../examples/stripe_settle/handler"

class TestStripeSettleExample < Minitest::Test
  def setup
    StripeSettleExample.reset!
    ENV["STRIPE_NETWORK_ID"] = "acct_machine_payments"
    ENV["SECRET_KEY"] = "example-secret"
    ENV["MPP_REALM"] = "localhost:4567"
    @server = StripeSettleExample.handler
  end

  def test_paid_challenge_advertises_machine_payments_account
    challenge = @server.charge(nil, "0.10", description: "Paid endpoint")

    assert_instance_of Mpp::Challenge, challenge
    assert_equal "stripe", challenge.method
    assert_equal "charge", challenge.intent
    assert_equal "10", challenge.request["amount"]
    assert_equal "usd", challenge.request["currency"]
    assert_equal "acct_machine_payments", challenge.request["recipient"]
    assert_equal "acct_machine_payments", challenge.request.dig("methodDetails", "networkId")
    assert_equal ["card", "link"], challenge.request.dig("methodDetails", "paymentMethodTypes")
  end

  def test_paid_charge_settles_spt_without_stripe_secret_key
    challenge = @server.charge(nil, "0.10", description: "Paid endpoint")
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"spt" => "spt_demo_abc"}
    )

    result = @server.charge(credential.to_authorization, "0.10", description: "Paid endpoint")

    refute_instance_of Mpp::Challenge, result
    _credential, receipt = result
    assert_equal "pi_mock_1", receipt.reference
    assert_equal "stripe", receipt.method

    call = StripeSettleExample.settler.calls.fetch(0)
    assert_equal 10, call[:amount]
    assert_equal "spt_demo_abc", call[:spt]
    assert_equal "mpp_#{challenge.id}_spt_demo_abc", call[:idempotency_key]
    refute call[:idempotency_key].include?("sk_")
  end

  def test_paid_charge_rejects_replayed_spt
    challenge = @server.charge(nil, "0.10", description: "Paid endpoint")
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"spt" => "spt_demo_abc"}
    )
    authorization = credential.to_authorization

    @server.charge(authorization, "0.10", description: "Paid endpoint")
    error = assert_raises(Mpp::VerificationError) do
      @server.charge(authorization, "0.10", description: "Paid endpoint")
    end
    assert_equal "Payment has already been processed.", error.message
  end

  def test_paid_charge_surfaces_settler_decline
    challenge = @server.charge(nil, "0.10", description: "Paid endpoint")
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"spt" => "spt_declined_card"}
    )

    error = assert_raises(Mpp::VerificationError) do
      @server.charge(credential.to_authorization, "0.10", description: "Paid endpoint")
    end
    assert_match(/declined/i, error.message)
  end
end
