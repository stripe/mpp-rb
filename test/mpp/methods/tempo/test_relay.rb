# frozen_string_literal: true

require "test_helper"
require "json"
require "webmock/minitest"

class TestTempoRelay < Minitest::Test
  def setup
    @credential = Mpp::Credential.new(
      challenge: Mpp::ChallengeEcho.new(
        id: "challenge-123",
        realm: "api.example.com",
        method: "tempo",
        intent: "charge",
        request: "e30",
        expires: "2099-01-01T00:00:00.000Z"
      ),
      payload: {"type" => "transaction", "signature" => "0xabcdef1234567890"},
      source: "did:pkh:eip155:42431:0xabc"
    )
    @receipt_body = {
      success: true,
      receipt: {
        method: "tempo",
        reference: "0xdeadbeef",
        timestamp: "2026-08-22T00:00:00.000Z"
      }
    }
  end

  def test_validate_decodes_base64_request_into_an_object
    request = {
      "amount" => "10000",
      "currency" => "0x#{"20c0" + ("0" * 36)}",
      "methodDetails" => {"chainId" => 42_431}
    }
    credential = Mpp::Credential.new(
      challenge: Mpp::ChallengeEcho.new(
        id: "challenge-123",
        realm: "api.example.com",
        method: "tempo",
        intent: "charge",
        request: Mpp::Parsing.b64_encode(request),
        expires: "2099-01-01T00:00:00.000Z"
      ),
      payload: {"type" => "transaction", "signature" => "0xabcdef1234567890"}
    )
    relay = Mpp::Methods::Tempo::Relay.new("https://api.tempo.example")
    stub_request(:post, "https://api.tempo.example/v1/mpp/validate")
      .with { |http|
        body = JSON.parse(http.body)
        body.dig("challenge", "request") == request
      }
      .to_return(status: 200, body: {success: true}.to_json)
    stub_request(:post, "https://api.tempo.example/v1/mpp/broadcast")
      .to_return(status: 200, body: @receipt_body.to_json)

    relay.verify(credential, {})

    assert_requested :post, "https://api.tempo.example/v1/mpp/validate"
  end

  def test_validate_and_broadcast_post_expected_body
    relay = Mpp::Methods::Tempo::Relay.resolve({
      url: "https://api.tempo.example",
      headers: {"tempo-api-key" => "key_123"}
    })
    stub_request(:post, "https://api.tempo.example/v1/mpp/validate")
      .with { |request|
        body = JSON.parse(request.body)
        body.dig("challenge", "id") == "challenge-123" &&
          body.dig("payload", "type") == "transaction" &&
          request.headers["Tempo-Api-Key"] == "key_123"
      }
      .to_return(status: 200, body: {success: true}.to_json)
    stub_request(:post, "https://api.tempo.example/v1/mpp/broadcast")
      .with { |request|
        request.headers["Idempotency-Key"]&.start_with?("mpp_0x") &&
          request.headers["Tempo-Api-Key"] == "key_123"
      }
      .to_return(status: 200, body: @receipt_body.to_json)

    receipt = relay.verify(@credential, {})

    assert_equal "0xdeadbeef", receipt.reference
    assert_equal "tempo", receipt.method
  end

  def test_header_proc_receives_path
    paths = []
    relay = Mpp::Methods::Tempo::Relay.new(
      "https://api.tempo.example",
      headers: ->(path) {
        paths << path
        {"Authorization" => "Bearer jwt-for-#{path.split("/").last}"}
      }
    )
    stub_request(:post, "https://api.tempo.example/v1/mpp/validate")
      .with(headers: {"Authorization" => "Bearer jwt-for-validate"})
      .to_return(status: 200, body: {success: true}.to_json)
    stub_request(:post, "https://api.tempo.example/v1/mpp/broadcast")
      .with(headers: {"Authorization" => "Bearer jwt-for-broadcast"})
      .to_return(status: 200, body: @receipt_body.to_json)

    relay.verify(@credential, {})

    assert_equal ["/v1/mpp/validate", "/v1/mpp/broadcast"], paths
  end

  def test_nested_validate_broadcast_headers
    relay = Mpp::Methods::Tempo::Relay.new(
      "https://api.tempo.example",
      headers: -> {
        {
          "validate" => {"Authorization" => "Bearer validate-jwt"},
          "broadcast" => {"Authorization" => "Bearer broadcast-jwt"}
        }
      }
    )
    stub_request(:post, "https://api.tempo.example/v1/mpp/validate")
      .with(headers: {"Authorization" => "Bearer validate-jwt"})
      .to_return(status: 200, body: {success: true}.to_json)
    stub_request(:post, "https://api.tempo.example/v1/mpp/broadcast")
      .with(headers: {"Authorization" => "Bearer broadcast-jwt"})
      .to_return(status: 200, body: @receipt_body.to_json)

    relay.verify(@credential, {})
  end

  def test_api_key_alias_sets_tempo_api_key_header
    relay = Mpp::Methods::Tempo::Relay.resolve({
      api_base_url: "https://api.tempo.example",
      api_key: "key_from_alias"
    })
    stub_request(:post, "https://api.tempo.example/v1/mpp/validate")
      .with(headers: {"Tempo-Api-Key" => "key_from_alias"})
      .to_return(status: 200, body: {success: true}.to_json)
    stub_request(:post, "https://api.tempo.example/v1/mpp/broadcast")
      .to_return(status: 200, body: @receipt_body.to_json)

    relay.verify(@credential, {})
  end

  def test_default_api_base_url
    relay = Mpp::Methods::Tempo::Relay.resolve({api_key: "key_123"})

    assert_equal "https://api.tempo.xyz", relay.base_url
  end

  def test_expired_code_raises_payment_expired
    relay = Mpp::Methods::Tempo::Relay.new("https://api.tempo.example")
    stub_request(:post, "https://api.tempo.example/v1/mpp/validate")
      .to_return(status: 200, body: {success: false, error: {code: "expired"}}.to_json)

    assert_raises(Mpp::PaymentExpiredError) do
      relay.verify(@credential, {})
    end
  end

  def test_already_used_raises_verification_failed
    relay = Mpp::Methods::Tempo::Relay.new("https://api.tempo.example")
    stub_request(:post, "https://api.tempo.example/v1/mpp/validate")
      .to_return(status: 200, body: {success: false, error: {code: "already_used"}}.to_json)

    error = assert_raises(Mpp::VerificationFailedError) do
      relay.verify(@credential, {})
    end
    assert_match(/already used/, error.message)
  end

  def test_http_error_raises
    relay = Mpp::Methods::Tempo::Relay.new("https://api.tempo.example")
    stub_request(:post, "https://api.tempo.example/v1/mpp/validate")
      .to_return(status: 401, body: {error: "unauthorized"}.to_json)

    error = assert_raises(Mpp::VerificationFailedError) do
      relay.verify(@credential, {})
    end
    assert_match(/HTTP 401/, error.message)
  end

  def test_resolve_passes_through_duck_typed_client
    client = DuckRelay.new
    resolved = Mpp::Methods::Tempo::Relay.resolve(client)

    assert_same client, resolved
  end

  def test_tempo_accepts_relay_config
    method = Mpp::Methods::Tempo.tempo(
      recipient: "0x#{"0" * 39}1",
      relay: {
        url: "https://api.tempo.example",
        headers: -> { {"tempo-api-key" => "key_123"} }
      },
      intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new}
    )

    assert_instance_of Mpp::Methods::Tempo::Relay, method.relay
    assert_equal "https://api.tempo.example", method.relay.base_url
  end

  def test_charge_intent_delegates_to_relay
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    Mpp::Methods::Tempo.tempo(
      recipient: "0x#{"0" * 39}1",
      relay: {
        url: "https://api.tempo.example",
        headers: {"tempo-api-key" => "key_123"}
      },
      intents: {"charge" => intent}
    )
    stub_request(:post, "https://api.tempo.example/v1/mpp/validate")
      .to_return(status: 200, body: {success: true}.to_json)
    stub_request(:post, "https://api.tempo.example/v1/mpp/broadcast")
      .to_return(status: 200, body: @receipt_body.to_json)

    receipt = intent.verify(@credential, {
      "amount" => "10000",
      "currency" => Mpp::Methods::Tempo::Defaults::PATH_USD,
      "recipient" => "0x#{"0" * 39}1"
    })

    assert_equal "0xdeadbeef", receipt.reference
    assert_not_requested :post, /rpc/
  end

  DuckRelay = Struct.new(:calls) do
    def initialize
      super([])
    end

    def validate(input)
      calls << [:validate, input]
      true
    end

    def broadcast(input)
      calls << [:broadcast, input]
      Mpp::Receipt.success("0xduck")
    end
  end
end
