require "dotenv/load"
require "sinatra"
require "json"
require "mpp-rb"

RECIPIENT_ADDRESS = ENV.fetch("RECIPIENT_ADDRESS")
SECRET_KEY = ENV.fetch("SECRET_KEY")

server = Mpp.create(
  method: Mpp::Methods::Tempo.tempo(
    chain_id: Mpp::Methods::Tempo::Defaults::TESTNET_CHAIN_ID,
    currency: Mpp::Methods::Tempo::Defaults::PATH_USD,
    recipient: RECIPIENT_ADDRESS,
    intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new}
  ),
  realm: "localhost:4567",
  secret_key: SECRET_KEY
)

get "/free" do
  content_type :json
  JSON.generate({message: "This endpoint is free."})
end

get "/paid" do
  result = server.charge(env["HTTP_AUTHORIZATION"], "0.01",
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
