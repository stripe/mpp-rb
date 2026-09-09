# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"
require "minitest/mock"

class TestEvmCharge < Minitest::Test
  SECRET = "test-evm-secret"
  REALM = "api.example.com"
  RECIPIENT = "0x#{"0" * 39}1"
  PAYER = "0x#{"0" * 39}2"
  URL = "https://api.example.com/paid"
  FACILITATOR = "https://x402.example/facilitator"

  def setup
    @method = Mpp::Methods::Evm.charge(
      currency: Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC,
      recipient: RECIPIENT,
      x402: {facilitator: FACILITATOR}
    )
    @handler = Mpp::Server::MppHandler.new(method: @method, realm: REALM, secret_key: SECRET)
  end

  def test_factory_requires_facilitator
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Evm.charge(
        currency: Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC,
        recipient: RECIPIENT,
        x402: {}
      )
    end
    assert_match(/facilitator/, error.message)
  end

  def test_known_asset_infers_chain_and_decimals
    assert_equal 84532, @method.chain_id
    assert_equal 6, @method.decimals
    assert_equal "evm", @method.name
  end

  def test_factory_exposes_payment_success_hook
    hook = ->(_payload) {}
    method = Mpp::Methods::Evm.charge(
      currency: Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC,
      recipient: RECIPIENT,
      x402: {facilitator: FACILITATOR},
      on_payment_success: hook
    )

    assert_same hook, method.on_payment_success
  end

  def test_factory_requires_a_callable_payment_success_hook
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Evm.charge(
        currency: Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC,
        recipient: RECIPIENT,
        x402: {facilitator: FACILITATOR},
        on_payment_success: Object.new
      )
    end

    assert_equal "on_payment_success must be callable", error.message
  end

  def test_factory_exposes_offer_availability_hook
    seen = []
    method = Mpp::Methods::Evm.charge(
      currency: Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC,
      recipient: RECIPIENT,
      x402: {facilitator: FACILITATOR},
      can_offer: lambda { |request|
        seen << request
        false
      }
    )

    refute method.can_offer?({"amount" => "10000"})
    assert_equal [{"amount" => "10000"}], seen
    assert @method.can_offer?({"amount" => "10000"})
  end

  def test_factory_requires_a_callable_offer_availability_hook
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Evm.charge(
        currency: Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC,
        recipient: RECIPIENT,
        x402: {facilitator: FACILITATOR},
        can_offer: Object.new
      )
    end

    assert_equal "can_offer must be callable", error.message
  end

  def test_charge_returns_native_challenge
    result = @handler.charge(nil, "0.01")

    assert_instance_of Mpp::Challenge, result
    assert_equal "evm", result.method
    assert_equal "charge", result.intent
    assert_equal "10000", result.request["amount"]
    assert_equal 84532, result.request.dig("methodDetails", "chainId")
    assert_equal ["authorization"], result.request.dig("methodDetails", "credentialTypes")
  end

  def test_challenge_response_includes_payment_required
    challenge = @handler.charge(nil, "0.01")
    response = @handler.challenge_response(challenge, url: URL, http_method: "GET")

    assert_equal 402, response["status"]
    encoded = response["headers"]["PAYMENT-REQUIRED"]
    refute_nil encoded
    decoded = Mpp::X402::Header.decode_payment_required(encoded)
    assert_equal URL, decoded["resource"]["url"]
    assert_equal "exact", decoded["accepts"][0]["scheme"]
    assert_equal "eip155:84532", decoded["accepts"][0]["network"]
    assert_equal "10000", decoded["accepts"][0]["amount"]
  end

  def test_x402_accepted_mismatch_returns_challenge
    challenge = @handler.charge(nil, "0.01")
    payload = x402_payload(challenge, accepted_overrides: {"amount" => "1"})
    result = @handler.charge(nil, "0.01", payment_signature: encode_signature(payload), url: URL)

    assert_instance_of Mpp::Challenge, result
  end

  def test_x402_resource_mismatch_returns_challenge
    challenge = @handler.charge(nil, "0.01")
    payload = x402_payload(challenge, resource_url: "https://api.example.com/other")
    result = @handler.charge(nil, "0.01", payment_signature: encode_signature(payload), url: URL)

    assert_instance_of Mpp::Challenge, result
  end

  def test_post_challenge_includes_body_digest
    result = @handler.charge(nil, "0.01", body: '{"ok":true}')

    assert_equal Mpp::BodyDigest.compute('{"ok":true}'), result.digest
  end

  def test_route_binding_required_rejects_unbound_payload
    method = Mpp::Methods::Evm.charge(
      currency: Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC,
      recipient: RECIPIENT,
      x402: {facilitator: FACILITATOR, route_binding: :required}
    )
    handler = Mpp::Server::MppHandler.new(method: method, realm: REALM, secret_key: SECRET)
    challenge = handler.charge(nil, "0.01", body: '{"query":"paid"}')
    payload = x402_payload(challenge)
    result = handler.charge(
      nil,
      "0.01",
      payment_signature: encode_signature(payload),
      url: URL,
      body: '{"query":"paid"}'
    )

    assert_instance_of Mpp::Challenge, result
  end

  def test_successful_x402_payment_settles_via_facilitator
    stub_facilitator(transaction: "0xsettled")
    challenge = @handler.charge(nil, "0.01")
    payload = x402_payload(challenge)
    signature = encode_signature(payload)

    result = nil
    Mpp::Methods::Evm::Authorization.stub(:recover, PAYER) do
      result = @handler.charge(nil, "0.01", payment_signature: signature, url: URL)
    end

    refute_instance_of Mpp::Challenge, result
    credential, receipt = result
    assert_equal "evm", receipt.method
    assert_equal "0xsettled", receipt.reference
    assert credential.payload["_x402"]

    headers = {}
    @method.decorate_receipt(headers, receipt, credential, payment_signature: signature)
    decoded = Mpp::X402::Header.decode_payment_response(headers["PAYMENT-RESPONSE"])
    assert_equal true, decoded["success"]
    assert_equal "0xsettled", decoded["transaction"]
    assert_equal PAYER, decoded["payer"]
  end

  def test_payment_success_hook_runs_after_x402_settlement
    seen = []
    method = Mpp::Methods::Evm.charge(
      currency: Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC,
      recipient: RECIPIENT,
      x402: {facilitator: FACILITATOR},
      on_payment_success: ->(payload) { seen << payload }
    )
    handler = Mpp::Server::MppHandler.new(method: method, realm: REALM, secret_key: SECRET)
    stub_facilitator(transaction: "0xsettled")
    challenge = handler.charge(nil, "0.01")

    Mpp::Methods::Evm::Authorization.stub(:recover, PAYER) do
      handler.charge(nil, "0.01", payment_signature: encode_signature(x402_payload(challenge)), url: URL)
    end

    assert_equal 1, seen.length
    assert_equal({name: "evm", intent: "charge"}, seen.first[:method])
    assert_equal "0xsettled", seen.first[:receipt].reference
  end

  def test_failed_facilitator_verify_returns_challenge
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(status: 200, body: {isValid: false, invalidReason: "insufficient"}.to_json)
    challenge = @handler.charge(nil, "0.01")
    result = nil
    Mpp::Methods::Evm::Authorization.stub(:recover, PAYER) do
      result = @handler.charge(nil, "0.01", payment_signature: encode_signature(x402_payload(challenge)), url: URL)
    end

    assert_instance_of Mpp::Challenge, result
  end

  def test_compose_flattens_x402_accepts
    tempo = ComposeLikeMethod.new
    handler = Mpp::Server::MppHandler.new(methods: [tempo, @method], realm: REALM, secret_key: SECRET)
    result = handler.compose(
      [tempo, {amount: "0.01"}],
      [@method, {amount: "0.01"}]
    ).call(url: URL, http_method: "GET")

    encoded = result.extra_headers["PAYMENT-REQUIRED"]
    refute_nil encoded
    decoded = Mpp::X402::Header.decode_payment_required(encoded)
    assert_equal 1, decoded["accepts"].length
    assert_equal "exact", decoded["accepts"][0]["scheme"]
    assert_equal 2, result.challenges.length
  end

  private

  def requirements_for(challenge)
    Mpp::X402::Server.to_payment_requirements(
      challenge.request,
      authorization: @method.authorization,
      max_timeout_seconds: 300
    )
  end

  def x402_payload(challenge, accepted_overrides: {}, resource_url: URL)
    {
      "accepted" => requirements_for(challenge).merge(accepted_overrides),
      "payload" => {
        "authorization" => {
          "from" => PAYER,
          "nonce" => "0x#{"11" * 32}",
          "to" => RECIPIENT,
          "validAfter" => "0",
          "validBefore" => (Time.now.to_i + 600).to_s,
          "value" => challenge.request["amount"]
        },
        "signature" => "0x#{"22" * 65}"
      },
      "resource" => {"url" => resource_url},
      "x402Version" => 2
    }
  end

  def encode_signature(payload)
    Mpp::X402::Header.encode_payment_signature(payload)
  end

  def stub_facilitator(transaction:)
    stub_request(:post, "#{FACILITATOR}/verify")
      .to_return(status: 200, body: {isValid: true, payer: PAYER}.to_json)
    stub_request(:post, "#{FACILITATOR}/settle")
      .to_return(status: 200, body: {
        success: true,
        transaction: transaction,
        network: "eip155:84532",
        payer: PAYER
      }.to_json)
  end

  class ComposeLikeMethod
    attr_reader :name, :intents, :currency, :recipient, :decimals

    def initialize
      @name = "tempo"
      @currency = Mpp::Methods::Tempo::Defaults::PATH_USD
      @recipient = "0x#{"0" * 39}1"
      @decimals = 6
      @intents = {"charge" => Intent.new}
    end

    class Intent
      def name
        "charge"
      end

      def verify(_credential, _request)
        Mpp::Receipt.success("0xtempo", method: "tempo")
      end
    end
  end
end
