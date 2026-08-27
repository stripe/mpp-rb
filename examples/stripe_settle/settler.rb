# frozen_string_literal: true

module StripeSettleExample
  # Stand-in for a privileged PaymentIntent create (internal RPC, Gator, etc.).
  # No Stripe secret key: the adapter decides merchant context and auth.
  class InMemorySptSettler
    attr_reader :calls

    def initialize
      @by_key = {}
      @seq = 0
      @calls = []
    end

    def call(amount:, currency:, spt:, payment_method_types:, idempotency_key:, metadata: nil)
      @calls << {
        amount: amount,
        currency: currency,
        spt: spt,
        payment_method_types: payment_method_types,
        idempotency_key: idempotency_key,
        metadata: metadata
      }

      if spt.to_s.start_with?("spt_declined")
        raise StandardError, "Your card was declined."
      end

      if (prior = @by_key[idempotency_key])
        return prior.merge(replayed: true)
      end

      @seq += 1
      result = {id: "pi_mock_#{@seq}", status: "succeeded"}
      @by_key[idempotency_key] = result.dup
      result.merge(replayed: false)
    end
  end
end
