# Stripe settle (no secret key)

Charge an endpoint with Stripe Shared Payment Tokens (SPTs), but settle the PaymentIntent through a custom `settle:` callable instead of `sk_live` / `sk_test`.

This is the seam for backends that already have a privileged PaymentIntent API — for example Stripe-internal services charging a global Machine Payments account — and should not hold a merchant secret key.

## Setup

```sh
cd examples/stripe_settle
bundle install
bundle exec ruby app.rb
```

No Stripe API key is required. The server starts on `http://localhost:4567`.

## Endpoints

| Endpoint | Price |
|----------|-------|
| `GET /free` | Free |
| `GET /paid` | $0.10, settled in-process |

## Pay with the demo client

In another terminal:

```sh
bundle exec ruby client.rb
```

The client sees the 402, mints a fake SPT (`spt_demo_…`), and retries. The in-memory settler confirms it as `pi_mock_1` and the server returns `Payment-Receipt`.

## What to swap internally

`handler.rb` passes `settle:` into `Mpp::Methods::Stripe.stripe`. The example uses `InMemorySptSettler`; a Stripe service would pass an adapter that creates+confirms a PaymentIntent **as** the Machine Payments merchant:

```ruby
server = Mpp.create(
  method: Mpp::Methods::Stripe.stripe(
    network_id: "acct_machine_payments",
    payment_methods: ["card", "link"],
    settle: ->(amount:, currency:, spt:, payment_method_types:, idempotency_key:, metadata: nil) {
      # Internal command, not Stripe::StripeClient.new(sk)
      pi = PaymentIntentService.create_and_confirm(
        merchant: "acct_machine_payments",
        amount: amount,
        currency: currency,
        shared_payment_granted_token: spt,
        payment_method_types: payment_method_types,
        metadata: metadata,
        idempotency_key: idempotency_key
      )
      {id: pi.id, status: pi.status, replayed: pi.replayed}
    }
  ),
  secret_key: hmac_secret  # MPP challenge HMAC, not a Stripe sk
)
```

`settle` may also be an object that implements `#settle` with the same keyword arguments.

Return `{id:, status:}` on success. Set `replayed: true` when the idempotency key already settled that SPT so MPP can reject "Payment has already been processed."

`Mpp.create(secret_key:)` is still required. That value is the challenge HMAC, not a Stripe API key.
