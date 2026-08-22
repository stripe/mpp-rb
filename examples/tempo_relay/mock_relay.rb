require "dotenv/load"
require "sinatra"
require "json"
require "time"

PORT = Integer(ENV.fetch("PORT", "4571"))
API_KEY = ENV.fetch("TEMPO_API_KEY", "test-tempo-api-key")

set :port, PORT
set :bind, ENV.fetch("BIND", "127.0.0.1")

configure do
  warn "Mock Tempo relay on http://#{settings.bind}:#{settings.port}"
  warn "  POST /v1/mpp/validate"
  warn "  POST /v1/mpp/broadcast  (tempo-api-key: #{API_KEY})"
end

helpers do
  def json_body
    JSON.parse(request.body.read)
  rescue JSON::ParserError
    halt 400, JSON.generate({success: false, error: {code: "invalid_payment", message: "invalid JSON"}})
  end

  def require_api_key!
    provided = request.env["HTTP_TEMPO_API_KEY"]
    return if provided == API_KEY

    halt 401, JSON.generate({success: false, error: {code: "unknown", message: "unauthorized"}})
  end
end

post "/v1/mpp/validate" do
  require_api_key!
  body = json_body
  unless body["challenge"].is_a?(Hash) && body["payload"].is_a?(Hash)
    halt 200, JSON.generate({success: false, error: {code: "invalid_payment"}})
  end

  content_type :json
  JSON.generate({success: true})
end

post "/v1/mpp/broadcast" do
  require_api_key!
  body = json_body
  reference = body.dig("payload", "signature") || body.dig("payload", "hash") || "0xrelayed"
  content_type :json
  JSON.generate({
    success: true,
    receipt: {
      method: "tempo",
      reference: reference,
      timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    }
  })
end
