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

Tempo charge transaction construction is implemented directly in Ruby. Optional dependencies: `eth` (account signing and attribution memo verification, so Tempo servers need it too) and `rlp` (fee payer envelope).

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
