# Ruby interop adapter

This note describes a small adapter shape for running `mpp-rb` in
cross-language MPP conformance tests. It is intentionally process-oriented so it
can plug into an external interop harness without adding a new runtime
dependency to the gem.

## Goals

- Exercise the same HTTP 402 flow that real Rack, Rails, or Sinatra apps use.
- Keep the Ruby SDK responsible for MPP parsing, credential construction, and
  receipt verification.
- Keep the harness responsible for process lifecycle, port allocation, and
  selecting client/server pairs.
- Make client and server adapters independent so either side can be added to a
  conformance matrix first.

## Process contract

An interop harness should be able to start Ruby adapters as ordinary processes:

```sh
ruby docs/interop/client_adapter.rb --url http://127.0.0.1:4567/paid
ruby docs/interop/server_adapter.rb --port 4567
```

The exact script paths can change, but the contract should stay small:

| Adapter | Required input | Expected behavior |
| --- | --- | --- |
| Client | Paid resource URL, optional method config | Sends the initial request, handles the Payment challenge, retries with `Authorization: Payment`, and exits non-zero on failure. |
| Server | Bind host/port, method config | Serves a paid endpoint, returns `WWW-Authenticate: Payment` when no credential is present, verifies credentials, and returns `Payment-Receipt` on success. |

Adapters should print structured JSON to stdout for harness assertions and
human-readable diagnostics to stderr.

## Client mapping

The Ruby client adapter should wrap the existing transport API:

```ruby
transport = Mpp::Client::Transport.new(methods: [method])
response = transport.request(:get, paid_url)
```

The harness-visible result should include:

- final HTTP status
- whether a Payment challenge was observed
- whether an `Authorization: Payment` retry was sent
- whether a `Payment-Receipt` header was returned
- method name, network, and receipt reference when available

## Server mapping

The Ruby server adapter can start with the same primitives used by the examples:

```ruby
handler = Mpp.create(method: method)
use Mpp::Server::Middleware, handler: handler
```

The paid route should set:

```ruby
env["mpp.charge"] = { amount: "0.50", description: "Interop paid endpoint" }
```

The harness-visible result should confirm:

- unauthenticated requests receive HTTP 402
- `WWW-Authenticate` contains a Payment challenge
- successful paid requests include `Payment-Receipt`
- paid responses vary on authorization where the hosting framework supports it

## Method configuration

Adapters should accept method configuration from environment variables or a JSON
file supplied by the harness. A minimal shape is:

```json
{
  "method": "tempo",
  "network": "testnet",
  "amount": "0.50",
  "recipient": "0x0000000000000000000000000000000000000001"
}
```

Stripe and Tempo method-specific fields should stay opaque to the harness where
possible. The harness should assert observable MPP behavior, not the internal
shape of provider-specific SDK objects.

## First implementation slice

1. Add a client adapter that can pay a known reference server.
2. Add a server adapter that serves one paid endpoint.
3. Add focused adapter smoke tests in this repository.
4. Wire the Ruby adapters into the shared matrix only after the local adapter
   tests are stable.

This keeps the first PRs small while still moving Ruby toward cross-language
MPP conformance.
