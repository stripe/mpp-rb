# mpp-rb

Ruby SDK for the [**Machine Payments Protocol**](https://mpp.dev)

[![Gem Version](https://img.shields.io/gem/v/mpp-rb.svg)](https://rubygems.org/gems/mpp-rb)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Documentation

Full documentation, API reference, and guides are available at **[mpp.dev/sdk/ruby](https://mpp.dev/sdk/ruby)**.

## Install

```bash
gem install mpp-rb
```

Or add to your Gemfile:

```ruby
gem "mpp-rb"
```

## Quick Start

### Server

```ruby
require "mpp-rb"

server = Mpp.create(
  method: Mpp::Methods::Tempo.tempo(
    intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new},
    recipient: "0x0000000000000000000000000000000000000001",
  ),
)

# In your request handler (Sinatra, Rails, Rack, etc.)
result = server.charge(authorization_header, "0.50", description: "Paid endpoint")

if result.is_a?(Mpp::Challenge)
  # Return 402 with WWW-Authenticate header
  resp = Mpp::Server::Decorator.make_challenge_response(result, server.realm)
  # resp["status"], resp["headers"], resp["body"]
else
  credential, receipt = result
  # credential.source — payer address
  # receipt.to_payment_receipt — Payment-Receipt header value
end
```

If the endpoint already uses `Authorization` (API keys, Bearer tokens), create the server with `requires_auth: true`. Challenges then advertise `header="Payment-Authorization"`, and clients send the Payment credential in that header instead of `Authorization`.

```ruby
server = Mpp.create(method: tempo, requires_auth: true)

result = server.charge(
  env["HTTP_AUTHORIZATION"],
  "0.50",
  payment_authorization: env["HTTP_PAYMENT_AUTHORIZATION"],
)
```

### Multiple methods

```ruby
server = Mpp.create(methods: [tempo, evm, stripe])

paid = server.compose(
  [tempo, {amount: "0.01"}],
  [evm, {amount: "0.01"}],
  [stripe, {amount: "0.01", currency: "usd"}]
)

result = paid.call(
  authorization: env["HTTP_AUTHORIZATION"],
  payment_authorization: env["HTTP_PAYMENT_AUTHORIZATION"],
  payment_signature: env["HTTP_PAYMENT_SIGNATURE"],
  accept_payment: env["HTTP_ACCEPT_PAYMENT"],
  url: request.url,
  http_method: request.request_method
)

if result.payment_required?
  resp = result.to_response
else
  credential, receipt = result.payment
end
```

### Stripe machine payments

`Mpp::Methods::Stripe.create` configures Stripe Payment Tokens and static
crypto deposit addresses from an injected Stripe client. Add the `stripe` gem
to your application, then configure the methods:

```ruby
require "stripe"

stripe_client = Stripe::StripeClient.new(ENV.fetch("STRIPE_SECRET_KEY"))
payments = Mpp::Methods::Stripe.create(
  client: stripe_client,
  network_id: ENV.fetch("STRIPE_NETWORK_ID"),
  livemode: false,
  deposit_addresses: {
    tempo: ENV.fetch("TEMPO_DEPOSIT_ADDRESS"),
    base: ENV.fetch("BASE_DEPOSIT_ADDRESS")
  },
  metadata: {"product" => "example"}
)

server = Mpp.create(methods: payments.default_methods)
```

With no deposit addresses, defaults are Stripe Payment Tokens only.
`default_methods` adds Tempo when its static address is configured. Add Base
explicitly with its x402 facilitator:

```ruby
base = payments.base.charge(
  x402: {facilitator: "https://x402.org/facilitator"}
)
server = Mpp.create(methods: [*payments.default_methods, base])
```

When composed, SPT offers below $0.50 and Tempo/Base offers below one cent are
not advertised. Successful Tempo and Base payments are best-effort recorded as
Stripe crypto transaction-verification PaymentIntents. Metadata is included on
every Stripe PaymentIntent.

Stripe machine-payment methods also accept private, request-scoped
`payment_intent_options` in `charge` or composed-offer input. Supported fields
match mppx: `customer`, `receipt_email`, `metadata`, and Stripe Tax calculation
hooks. The value can be a static hash or a deferred callable:

```ruby
options = lambda do |challenge:, credential:, request:|
  calculation = stripe_client.v1.tax.calculations.create(
    tax_params,
    {idempotency_key: "mpp_tax_#{challenge.id}"}
  )
  {hooks: {inputs: {tax: {calculation: calculation.id}}}}
end

payment = server.compose(
  [payments.tempo.charge, {amount: "0.50", payment_intent_options: options}],
  [payments.spt.charge, {amount: "0.50", payment_intent_options: options}]
)
```

Deferred callables run only after credential validation and immediately before
PaymentIntent creation or crypto settlement. The options are not serialized in
the MPP challenge. Recorded crypto payments retry once without optional fields
only when Stripe definitively rejects those fields.

`evm.charge` additionally emits `PAYMENT-REQUIRED` and accepts `PAYMENT-SIGNATURE` (x402 v2 exact) when a facilitator is configured:

```ruby
# Public / testnet facilitator
x402: {facilitator: "https://x402.org/facilitator"}

# Per-request headers (bearer token, CDP JWT, etc.)
x402: {facilitator: {url: facilitator_url, headers: -> { {"Authorization" => "Bearer #{token}"} }}}

# The proc may take the request path (`/verify`, `/settle`) when headers differ per call
x402: {facilitator: {url: cdp_url, headers: ->(path) { cdp_headers(path) }}}

# Any client with #verify / #settle
x402: {facilitator: cdp_client}
```

Tempo charge can sponsor gas through a hosted fee payer, or skip local RPC by sending credentials to a Tempo API-compatible relay. Both use the same `{url:, headers:}` shape as the x402 facilitator:

```ruby
# Hosted fee payer (JSON-RPC eth_signRawTransaction)
fee_payer: {url: sponsor_url, headers: -> { {"Authorization" => "Bearer #{token}"} }}

# Local co-sign
fee_payer: Mpp::Methods::Tempo::Account.from_key(ENV.fetch("FEE_PAYER_KEY"))

# Relay (POST /v1/mpp/validate then /v1/mpp/broadcast)
relay: {url: "https://api.tempo.xyz", headers: -> { {"tempo-api-key" => ENV.fetch("TEMPO_API_KEY")} }}
```

### Client

```ruby
require "mpp-rb"

account = Mpp::Methods::Tempo::Account.from_key("0x...")

transport = Mpp::Client::Transport.new(
  methods: [
    Mpp::Methods::Tempo.tempo(
      account: account,
      intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new},
    ),
  ],
)

response = transport.request(:get, "https://mpp.dev/api/ping/paid")
```

### Event hooks

Register hooks to observe the automatic payment lifecycle. Each registration returns an unsubscribe proc.

```ruby
server.on_challenge_created do |payload|
  puts "challenge: #{payload[:challenge].id}"
end

server.on_payment_success do |payload|
  puts "paid: #{payload[:receipt].reference}"
end

transport.on_challenge_received do |payload|
  puts "received: #{payload[:challenge].id}"
  nil
end

transport.on_payment_response do |payload|
  puts "retry status: #{payload[:response].code}"
end

transport.on("*") do |event|
  puts "payment event: #{event.name}"
end
```

Client events are `challenge.received`, `credential.created`, `payment.response`, and `payment.failed`. Server events are `challenge.created`, `payment.success`, and `payment.failed`.

When a side effect belongs to one payment method, attach it to the method instead. The hook only receives successful payments for that method and intent; an exception in the hook does not invalidate the payment.

```ruby
method = Mpp::Methods::Tempo.tempo(
  intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new},
  recipient: "0x0000000000000000000000000000000000000001",
  on_payment_success: ->(payload) {
    record_payment(payload[:receipt], payload[:request])
  },
)
```

### Rack Middleware

```ruby
require "mpp-rb"

handler = Mpp.create(
  method: Mpp::Methods::Tempo.tempo(
    intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new},
    recipient: "0x0000000000000000000000000000000000000001",
  ),
)

# In your config.ru or Rails middleware stack:
use Mpp::Server::Middleware, handler: handler

# In your app, signal that payment is required:
env["mpp.charge"] = { amount: "0.50", description: "Paid endpoint" }
```

## Examples

| Example | Description |
|---------|-------------|
| [tempo_charge](./examples/tempo_charge/) | Tempo testnet payments via Sinatra |
| [stripe_charge](./examples/stripe_charge/) | Stripe payments via Shared Payment Tokens |
| [compose](./examples/compose/) | Tempo + Base USDC + Stripe SPTs on one endpoint |
| [evm_x402](./examples/evm_x402/) | EVM charge with x402 exact compatibility |
| [tempo_feepayer](./examples/tempo_feepayer/) | Tempo charge with a hosted fee-payer `{url:, headers:}` |
| [tempo_relay](./examples/tempo_relay/) | Tempo charge delegated to an MPP relay `{url:, headers:}` |

Each example is a standalone Sinatra app with `/free` and `/paid` endpoints. To run one:

```sh
cd examples/tempo_charge
bundle install
ruby app.rb
```

Then test with [mppx](https://www.npmjs.com/package/mppx), a CLI that handles the full 402 challenge/credential flow:

```sh
npx mppx http://localhost:4567/paid
```

## Support Matrix

| Method | Charge Client | Charge Server |
|--------|---------------|---------------|
| Tempo | Yes | Yes |
| Stripe | Yes | Yes |
| EVM (`evm.charge`, x402 exact) | No | Yes |

Tempo charge transaction construction is implemented directly in Ruby. Runtime dependency: `keccak` (Tempo attribution memos). Optional dependencies: `eth` (account signing, EIP-3009 recovery) and `rlp` (fee payer envelope).

`Mpp.create` accepts a single `method:` (unchanged) or `methods:` to register several payment methods. `server.compose` presents every method as multiple `WWW-Authenticate` challenges; `evm.charge` also emits `PAYMENT-REQUIRED` and accepts `PAYMENT-SIGNATURE` when a facilitator is configured. The Ruby HTTP client does not yet sign EVM or x402 credentials.

## Protocol

Built on the ["Payment" HTTP Authentication Scheme](https://datatracker.ietf.org/doc/draft-ryan-httpauth-payment/). See [mpp-specs](https://tempoxyz.github.io/mpp-specs/) for the full specification.

## Releasing

1. Create a release PR:
   - Update the version in `lib/mpp/version.rb`
   - Run `bundle lock --update mpp-rb` in the root and each `examples/` subdirectory
   - Commit and open a PR to verify CI passes
2. Merge the PR
3. Tag the merge commit: `git tag v0.x.x`
4. Push the tag: `git push origin --tags`

## License

MIT
