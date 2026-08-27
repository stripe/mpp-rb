require "dotenv/load"
require "sinatra"
require "json"
require_relative "handler"

PORT = Integer(ENV.fetch("PORT", "4567"))
set :port, PORT
set :bind, ENV.fetch("BIND", "127.0.0.1")

server = StripeSettleExample.handler

configure do
  warn "Stripe settle example on http://#{settings.bind}:#{settings.port}"
  warn "  GET /free  — no payment"
  warn "  GET /paid  — $0.10 via SPT, settled without a Stripe secret key"
  warn "  network    — #{StripeSettleExample.network_id}"
end

get "/free" do
  content_type :json
  JSON.generate({message: "This endpoint is free."})
end

get "/paid" do
  result = server.charge(env["HTTP_AUTHORIZATION"], "0.10",
    description: "Paid endpoint")

  if result.is_a?(Mpp::Challenge)
    resp = Mpp::Server::Decorator.make_challenge_response(result, server.realm)
    status resp["status"]
    headers resp["headers"]
    body resp["body"]
    return
  end

  _credential, receipt = result
  headers "Payment-Receipt" => receipt.to_payment_receipt
  content_type :json
  JSON.generate({
    message: "Payment received.",
    reference: receipt.reference,
    method: receipt.method
  })
end
