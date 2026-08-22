# frozen_string_literal: true

require "mpp-rb"

module TempoRelayExample
  module_function

  def recipient
    ENV.fetch("RECIPIENT_ADDRESS", "0x#{"0" * 39}1")
  end

  def secret_key
    ENV.fetch("SECRET_KEY", "test-secret")
  end

  def relay_url
    ENV.fetch("RELAY_URL", "https://api.tempo.xyz")
  end

  def relay_api_key
    ENV.fetch("TEMPO_API_KEY", "test-tempo-api-key")
  end

  def realm
    ENV.fetch("MPP_REALM", "localhost:4567")
  end

  def handler
    Mpp.create(
      method: Mpp::Methods::Tempo.tempo(
        chain_id: Mpp::Methods::Tempo::Defaults::TESTNET_CHAIN_ID,
        currency: Mpp::Methods::Tempo::Defaults::PATH_USD,
        recipient: recipient,
        relay: {
          url: relay_url,
          headers: -> { {"tempo-api-key" => relay_api_key} }
        },
        intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new}
      ),
      realm: realm,
      secret_key: secret_key
    )
  end
end
