# frozen_string_literal: true

require "test_helper"

class TestMachinePayments < Minitest::Test
  TEMPO_ADDRESS = "0x#{"1" * 40}"
  BASE_ADDRESS = "0x#{"2" * 40}"

  class FakePaymentIntents
    attr_reader :calls

    def initialize
      @calls = []
    end

    def create(params, options)
      @calls << [params, options]
      Struct.new(:id, :status).new("pi_crypto", "succeeded")
    end
  end

  class FakeStripeClient
    attr_reader :payment_intents

    def initialize
      @payment_intents = FakePaymentIntents.new
    end

    def v1
      Struct.new(:payment_intents).new(@payment_intents)
    end
  end

  def test_default_methods_without_addresses_are_spt_only
    method = machine_payments.default_methods.fetch(0)

    assert_equal ["stripe"], machine_payments.default_methods.map(&:name)
    request = method.transform_request({"amount" => "100"}, nil)
    assert_equal "network_123", request.dig("methodDetails", "networkId")
    assert_equal ["card", "link"], request.dig("methodDetails", "paymentMethodTypes")
  end

  def test_default_methods_include_static_tempo_but_not_base
    payments = machine_payments(deposit_addresses: {tempo: TEMPO_ADDRESS, base: BASE_ADDRESS})

    methods = payments.default_methods

    assert_equal ["tempo", "stripe"], methods.map(&:name)
    assert_equal TEMPO_ADDRESS, methods.first.recipient
  end

  def test_tempo_uses_static_address_and_network_defaults
    test_tempo = machine_payments(deposit_addresses: {tempo: TEMPO_ADDRESS}).tempo.charge
    live_tempo = machine_payments(livemode: true, deposit_addresses: {tempo: TEMPO_ADDRESS}).tempo.charge

    assert_equal TEMPO_ADDRESS, test_tempo.recipient
    assert_equal Mpp::Methods::Tempo::Defaults::TESTNET_CHAIN_ID, test_tempo.chain_id
    assert_equal Mpp::Methods::Tempo::Defaults::PATH_USD, test_tempo.currency
    assert_equal Mpp::Methods::Tempo::Defaults::CHAIN_ID, live_tempo.chain_id
    assert_equal Mpp::Methods::Tempo::Defaults::USDC, live_tempo.currency
  end

  def test_deposit_addresses_are_static_recognized_addresses
    payments = machine_payments(deposit_addresses: {tempo: TEMPO_ADDRESS, base: BASE_ADDRESS})

    assert_equal TEMPO_ADDRESS, payments.tempo.charge.recipient
    assert_equal BASE_ADDRESS.downcase, payments.base.charge(x402: facilitator).recipient.downcase

    error = assert_raises(ArgumentError) { machine_payments(deposit_addresses: {celo: BASE_ADDRESS}) }
    assert_equal "unsupported deposit address network: celo", error.message
    error = assert_raises(ArgumentError) { machine_payments(deposit_addresses: {base: "not-an-address"}) }
    assert_equal "deposit_addresses[:base] must be a 0x-prefixed 40-hex-character address", error.message
  end

  def test_tempo_and_base_require_their_configured_addresses
    error = assert_raises(ArgumentError) { machine_payments.tempo.charge }
    assert_equal "deposit_addresses[:tempo] is required for Tempo payments", error.message

    error = assert_raises(ArgumentError) { machine_payments.base.charge(x402: facilitator) }
    assert_equal "deposit_addresses[:base] is required for Base payments", error.message
  end

  def test_base_requires_a_facilitator_and_selects_the_correct_usdc
    error = assert_raises(ArgumentError) do
      machine_payments(deposit_addresses: {base: BASE_ADDRESS}).base.charge(x402: {})
    end
    assert_equal "evm.charge requires x402: { facilitator: ... }", error.message

    test_base = machine_payments(deposit_addresses: {base: BASE_ADDRESS}).base.charge(x402: facilitator)
    live_base = machine_payments(livemode: true, deposit_addresses: {base: BASE_ADDRESS}).base.charge(x402: facilitator)

    assert_equal Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC.address.downcase, test_base.currency.downcase
    assert_equal Mpp::Methods::Evm::Assets::BASE_USDC.address.downcase, live_base.currency.downcase
  end

  def test_methods_enforce_the_fixed_minima
    payments = machine_payments(deposit_addresses: {tempo: TEMPO_ADDRESS, base: BASE_ADDRESS})

    refute payments.spt.charge.can_offer?({"amount" => "49"})
    assert payments.spt.charge.can_offer?({"amount" => "50"})
    refute payments.tempo.charge.can_offer?({"amount" => "9999"})
    assert payments.tempo.charge.can_offer?({"amount" => "10000"})
    refute payments.base.charge(x402: facilitator).can_offer?({"amount" => "9999"})
    assert payments.base.charge(x402: facilitator).can_offer?({"amount" => "10000"})
  end

  def test_tempo_and_base_record_verified_payments
    client = FakeStripeClient.new
    payments = machine_payments(
      client: client,
      deposit_addresses: {tempo: TEMPO_ADDRESS, base: BASE_ADDRESS},
      metadata: {"order" => 123}
    )

    payments.tempo.charge.on_payment_success.call(success_payload("0xtempo"))
    payments.base.charge(x402: facilitator).on_payment_success.call(success_payload("0xbase"))

    tempo_params, tempo_options = client.payment_intents.calls.fetch(0)
    base_params, base_options = client.payment_intents.calls.fetch(1)
    assert_equal 1, tempo_params[:amount]
    assert_equal "tempo", tempo_params.dig(:payment_method_options, :crypto, :transaction_verification_options, :network)
    assert_equal "base", base_params.dig(:payment_method_options, :crypto, :transaction_verification_options, :network)
    assert_equal "0xtempo", tempo_options[:idempotency_key]
    assert_equal "0xbase", base_options[:idempotency_key]
    assert_equal({"machine_payment" => "true", "order" => "123"}, tempo_params[:metadata])
    assert_equal({"machine_payment" => "true", "order" => "123"}, base_params[:metadata])
    assert_equal Mpp::Methods::Stripe::Defaults::MACHINE_PAYMENTS_API_VERSION, tempo_options[:stripe_version]
  end

  def test_spt_uses_the_injected_client
    client = FakeStripeClient.new
    method = machine_payments(client: client, metadata: {"order" => 123}).spt.charge
    request = method.transform_request({"amount" => "100", "currency" => "usd", "recipient" => "network_123"}, nil)
    challenge = Mpp::Challenge.create(secret_key: "secret", realm: "api.example.com", method: "stripe", intent: "charge", request: request)
    credential = Mpp::Credential.new(challenge: challenge.to_echo, payload: {"spt" => "spt_test"})

    method.intents.fetch("charge").verify(credential, request)

    params, = client.payment_intents.calls.first
    assert_equal "spt_test", params[:shared_payment_granted_token]
    assert_equal ["card", "link"], params[:payment_method_types]
    assert_equal({"machine_payment" => "true", "order" => "123"}, params[:metadata])
  end

  def test_crypto_recorder_rounds_before_applying_the_one_cent_minimum
    client = FakeStripeClient.new
    recorder = Mpp::Methods::Stripe::CryptoPaymentRecorder.new(client: client, network: "tempo")

    [4999, 5000, 14_999, 15_000].each do |amount|
      recorder.call(success_payload("0x#{amount}", amount: amount))
    end

    assert_equal [1, 1, 2], client.payment_intents.calls.map { |params, _options| params[:amount] }
  end

  def test_crypto_recording_failures_are_logged_without_failing_the_payment
    client = FakeStripeClient.new
    client.payment_intents.define_singleton_method(:create) { |_params, _options| raise "unavailable" }
    recorder = Mpp::Methods::Stripe::CryptoPaymentRecorder.new(client: client, network: "tempo")

    _stdout, stderr = capture_io { assert_nil recorder.call(success_payload("0xfailure")) }

    assert_includes stderr, "failed to record crypto payment"
    assert_includes stderr, 'network="tempo"'
    assert_includes stderr, 'transaction_hash="0xfailure"'
    assert_includes stderr, "RuntimeError: unavailable"

    receipt = Object.new
    receipt.define_singleton_method(:reference) { raise "invalid receipt" }

    _stdout, stderr = capture_io { assert_nil recorder.call({receipt: receipt}) }

    assert_includes stderr, 'network="tempo"'
    assert_includes stderr, "transaction_hash=nil"
  end

  def test_facade_requires_an_injected_client
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Stripe.create(network_id: "network_123", livemode: false)
    end

    assert_match(/missing keyword: :client/, error.message)
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Stripe.create(network_id: "network_123", livemode: false, client: nil)
    end
    assert_equal "client must respond to #v1", error.message
  end

  private

  def facilitator
    {facilitator: "https://x402.example"}
  end

  def success_payload(reference, amount: 10_000)
    {receipt: Mpp::Receipt.success(reference, method: "evm"), request: {"amount" => amount.to_s}}
  end

  def machine_payments(livemode: false, client: FakeStripeClient.new, deposit_addresses: nil, metadata: nil)
    Mpp::Methods::Stripe.create(
      network_id: "network_123",
      livemode: livemode,
      client: client,
      deposit_addresses: deposit_addresses,
      metadata: metadata
    )
  end
end
