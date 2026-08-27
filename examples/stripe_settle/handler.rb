# frozen_string_literal: true

require "mpp-rb"
require_relative "settler"

module StripeSettleExample
  class << self
    def network_id
      ENV.fetch("STRIPE_NETWORK_ID", "acct_machine_payments")
    end

    def secret_key
      ENV.fetch("SECRET_KEY", "test-secret")
    end

    def realm
      ENV.fetch("MPP_REALM", "localhost:4567")
    end

    def settler
      @settler ||= InMemorySptSettler.new
    end

    def reset!
      @settler = nil
    end

    # Builds an MPP server that accepts SPTs for a global Machine Payments
    # account without a Stripe API secret key. Swap `settler` for an adapter
    # that creates+confirms a PaymentIntent as that merchant.
    def handler
      Mpp.create(
        method: Mpp::Methods::Stripe.stripe(
          network_id: network_id,
          payment_methods: ["card", "link"],
          settle: settler
        ),
        realm: realm,
        secret_key: secret_key
      )
    end
  end
end
