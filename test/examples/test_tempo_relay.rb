# frozen_string_literal: true

require "test_helper"
require "json"
require "webmock/minitest"
require_relative "../../examples/tempo_relay/handler"

class TestTempoRelayExample < Minitest::Test
  RAW_TX = "0xabcdef1234567890"
  RELAY_URL = "https://relay.example.test"
  API_KEY = "test-tempo-api-key"

  def setup
    ENV["RELAY_URL"] = RELAY_URL
    ENV["TEMPO_API_KEY"] = API_KEY
    ENV["RECIPIENT_ADDRESS"] = "0x#{"0" * 39}1"
    ENV["SECRET_KEY"] = "example-secret"
    ENV["MPP_REALM"] = "localhost:4567"
    @server = TempoRelayExample.handler
  end

  def test_paid_challenge_is_standard_tempo_charge
    challenge = @server.charge(nil, "0.01", description: "Paid endpoint")

    assert_instance_of Mpp::Challenge, challenge
    assert_equal "tempo", challenge.method
    assert_equal "charge", challenge.intent
    assert_equal "10000", challenge.request["amount"]
  end

  def test_paid_charge_validates_and_broadcasts_through_relay
    challenge = @server.charge(nil, "0.01", description: "Paid endpoint")
    timestamp = "2026-08-22T17:00:00.000Z"

    stub_request(:post, "#{RELAY_URL}/v1/mpp/validate")
      .with { |request|
        body = JSON.parse(request.body)
        request.headers["Tempo-Api-Key"] == API_KEY &&
          body.dig("challenge", "id") == challenge.id &&
          body.dig("payload", "signature") == RAW_TX
      }
      .to_return(status: 200, body: {success: true}.to_json)

    stub_request(:post, "#{RELAY_URL}/v1/mpp/broadcast")
      .with { |request|
        request.headers["Tempo-Api-Key"] == API_KEY &&
          request.headers["Idempotency-Key"]&.start_with?("mpp_0x")
      }
      .to_return(status: 200, body: {
        success: true,
        receipt: {
          method: "tempo",
          reference: "0xrelayed",
          timestamp: timestamp
        }
      }.to_json)

    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "transaction", "signature" => RAW_TX}
    )
    result = @server.charge(credential.to_authorization, "0.01", description: "Paid endpoint")

    refute_instance_of Mpp::Challenge, result
    _credential, receipt = result
    assert_equal "0xrelayed", receipt.reference
    assert_equal "tempo", receipt.method
    assert_requested :post, "#{RELAY_URL}/v1/mpp/validate"
    assert_requested :post, "#{RELAY_URL}/v1/mpp/broadcast"
  end

  def test_paid_charge_rejects_missing_relay_auth
    challenge = @server.charge(nil, "0.01", description: "Paid endpoint")
    stub_request(:post, "#{RELAY_URL}/v1/mpp/validate")
      .to_return(status: 401, body: {error: "unauthorized"}.to_json)

    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "transaction", "signature" => RAW_TX}
    )

    error = assert_raises(Mpp::VerificationFailedError) do
      @server.charge(credential.to_authorization, "0.01", description: "Paid endpoint")
    end
    assert_match(/HTTP 401/, error.message)
  end
end
