# Tempo API relay example

Delegate Tempo charge validation and broadcast to a compatible MPP relay. The server never talks to chain RPC; it POSTs credentials to `/v1/mpp/validate` and `/v1/mpp/broadcast` with the same `{url:, headers:}` config used for x402 facilitators.

## Setup

```sh
cd examples/tempo_relay
bundle install
cp .env.template .env
# Edit .env and fill in TEMPO_API_KEY (mpp:write)
bundle exec ruby app.rb
```

To try the config against a local mock relay:

```sh
TEMPO_API_KEY=test-tempo-api-key bundle exec ruby mock_relay.rb
# in another terminal:
RELAY_URL=http://127.0.0.1:4571 TEMPO_API_KEY=test-tempo-api-key bundle exec ruby app.rb
```

The paid API starts on `http://localhost:4567`.

## Endpoints

| Endpoint | Price |
|----------|-------|
| `GET /free` | Free |
| `GET /paid` | $0.01, settled by the relay |

## Testing with mppx

```sh
npx mppx http://localhost:4567/paid
```
