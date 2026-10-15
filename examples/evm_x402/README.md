# EVM charge + x402 exact

Gate an endpoint behind EIP-3009 USDC on Base Sepolia. The same route speaks native MPP (`WWW-Authenticate` / `Authorization`) and x402 v2 exact (`PAYMENT-REQUIRED` / `PAYMENT-SIGNATURE` / `PAYMENT-RESPONSE`).

## Setup

```sh
cd examples/evm_x402
bundle install
# Set RECIPIENT_ADDRESS, SECRET_KEY, and optionally X402_FACILITATOR_URL
bundle exec ruby app.rb
```

This example depends on `eth` → `rbsecp256k1`, which compiles libsecp256k1 with autotools. On macOS:

```sh
brew install autoconf automake libtool
```

The server starts on `http://localhost:4567`.

## Endpoints

| Endpoint | Price |
|----------|-------|
| `GET /free` | Free |
| `GET /paid` | 0.01 USDC on Base Sepolia |

## Testing with mppx

Native MPP clients (including `mppx`) pay via `Authorization: Payment`:

```sh
npx mppx http://localhost:4567/paid
```

x402 exact clients read `PAYMENT-REQUIRED` and retry with `PAYMENT-SIGNATURE`.
They must use the route-bound `mppx` nonce described in the root README; a
standard EIP-3009 nonce does not authorize this resource. Inspect the dual-speak 402:

```sh
curl -i http://localhost:4567/paid
```
