# Stripe Charge Example

One-shot payments via Stripe Shared Payment Tokens (SPTs) using the MPP charge flow.

## Setup

```sh
cd examples/stripe_charge
bundle install
cp .env.template .env
# Edit .env and fill in your values
bundle exec ruby app.rb
```

The server starts on `http://localhost:4567`.

## Endpoints

| Endpoint | Price |
|----------|-------|
| `GET /free` | Free |
| `GET /paid` | $0.10 |

## Testing with mppx

[mppx](https://www.npmjs.com/package/mppx) is a CLI client that handles the MPP 402 challenge/credential flow automatically.

```sh
npx mppx http://localhost:4567/paid
```

`mppx` will:
1. Send a request to the endpoint
2. Receive a `402 Payment Required` with a `WWW-Authenticate: Payment` challenge
3. Construct and sign a Stripe payment credential
4. Retry the request with the `Authorization: Payment` header
5. Print the response body and `Payment-Receipt` header

To see the raw 402 challenge:

```sh
curl -i http://localhost:4567/paid
```
