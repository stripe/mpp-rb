require "dotenv/load"
require "sinatra"
require "json"
require "mpp-rb"

STRIPE_SECRET_KEY = ENV.fetch("STRIPE_SECRET_KEY")
STRIPE_NETWORK_ID = ENV.fetch("STRIPE_NETWORK_ID")
SECRET_KEY = ENV.fetch("SECRET_KEY")

server = Mpp.create(
  method: Mpp::Methods::Stripe.stripe(
    secret_key: STRIPE_SECRET_KEY,
    network_id: STRIPE_NETWORK_ID,
    currency: "usd",
    payment_methods: ["card", "link"]
  ),
  realm: "localhost:4567",
  secret_key: SECRET_KEY
)

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
  JSON.generate({message: "Payment received."})
end
