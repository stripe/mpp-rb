# typed: ignore
# frozen_string_literal: true

require "test_helper"

class TestTempoExpectedRecipients < Minitest::Test
  ALLOWED = "0x0000000000000000000000000000000000000001" # same as examples/
  OTHER = "0xabcd"
  CURRENCY = "0x20c0000000000000000000000000000000000000"

  def make_method(expected_recipients:)
    Mpp::Methods::Tempo::TempoMethod.new(
      account: stub_account,
      expected_recipients: expected_recipients
    )
  end

  def make_challenge(recipient:, splits: nil)
    request = {
      "amount" => "1000000",
      "currency" => "USD",
      "recipient" => recipient
    }
    request["methodDetails"] = {"splits" => splits} if splits

    Mpp::Challenge.new(
      id: "test-id",
      method: "tempo",
      intent: "charge",
      request: request,
      realm: "test.example.com"
    )
  end

  def stub_account
    Struct.new(:address, :type) do
      def sign_hash(_digest)
        "\x33" * 64 + "\x1b"
      end
    end.new("0x0000000000000000000000000000000000000001", "local")
  end

  def test_rejects_unexpected_recipient
    method = make_method(expected_recipients: [ALLOWED])
    challenge = make_challenge(recipient: OTHER)

    err = assert_raises(ArgumentError) do
      method.create_credential(challenge)
    end
    assert_equal "Unexpected recipient: #{OTHER}", err.message
  end

  def test_allows_expected_recipient
    method = make_method(expected_recipients: [ALLOWED])
    challenge = make_challenge(recipient: ALLOWED)

    # Should pass recipient validation — no ArgumentError about unexpected recipient
    method.stub(:build_tempo_transfer, ["0xdeadbeef", 4217]) do
      assert method.create_credential(challenge)
    end
  end

  def test_expected_recipients_case_insensitive
    method = make_method(expected_recipients: [ALLOWED.downcase])
    challenge = make_challenge(recipient: ALLOWED.upcase)

    method.stub(:build_tempo_transfer, ["0xdeadbeef", 4217]) do
      assert method.create_credential(challenge)
    end
  end

  def test_rejects_unexpected_split_recipient
    method = make_method(expected_recipients: [ALLOWED])
    challenge = make_challenge(
      recipient: ALLOWED,
      splits: [{"recipient" => OTHER, "amount" => "500000"}]
    )

    err = assert_raises(ArgumentError) do
      method.create_credential(challenge)
    end
    assert_equal "Unexpected split recipient: #{OTHER}", err.message
  end

  def test_allows_expected_split_recipients
    method = make_method(expected_recipients: [ALLOWED, OTHER])
    challenge = make_challenge(
      recipient: ALLOWED,
      splits: [{"recipient" => OTHER, "amount" => "500000"}]
    )

    method.stub(:build_tempo_transfer, ["0xdeadbeef", 4217]) do
      assert method.create_credential(challenge)
    end
  end

  def test_skips_validation_when_no_allowlist
    method = Mpp::Methods::Tempo::TempoMethod.new(account: stub_account)
    challenge = make_challenge(recipient: OTHER)

    method.stub(:build_tempo_transfer, ["0xdeadbeef", 4217]) do
      assert method.create_credential(challenge)
    end
  end

  def test_awaiting_fee_payer_caps_gas_price_to_policy
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    method = Mpp::Methods::Tempo::TempoMethod.new(account: stub_account)
    Mpp::Methods::Tempo::Rpc.stub(:get_tx_params, [42_431, 0, 60_000_000_000]) do
      Mpp::Methods::Tempo::Rpc.stub(:estimate_gas, 21_000) do
        raw_tx, = method.send(
          :build_tempo_transfer,
          amount: 1_000_000,
          currency: CURRENCY,
          recipient: ALLOWED,
          memo: "0x#{"11" * 32}",
          rpc_url: "http://localhost:8545",
          expected_chain_id: 42_431,
          awaiting_fee_payer: true
        )

        decoded = decode_raw_tx(raw_tx, 0x78)

        assert_equal 50_000_000_000, int_value(decoded[1])
        assert_equal 60_000_000_000, int_value(decoded[2])
      end
    end
  end

  def eth_and_rlp_available?
    require "eth"
    require "rlp"
    true
  rescue LoadError
    false
  end

  def decode_raw_tx(raw_tx, prefix)
    require "rlp"

    bytes = [raw_tx.delete_prefix("0x")].pack("H*")
    assert_equal prefix, bytes.getbyte(0)
    RLP.decode(bytes[1..])
  end

  def int_value(value)
    return value if value.is_a?(Integer)
    return 0 if value.nil? || value == ""

    value.unpack1("H*").to_i(16)
  end
end

class TestTempoMethodPaymentSuccessHook < Minitest::Test
  def test_factory_exposes_payment_success_hook
    hook = ->(_payload) {}
    intent = Struct.new(:name).new("charge")

    method = Mpp::Methods::Tempo.tempo(
      intents: {"charge" => intent},
      on_payment_success: hook
    )

    assert_same hook, method.on_payment_success
  end

  def test_rejects_non_callable_payment_success_hook
    [false, "not callable"].each do |hook|
      error = assert_raises(ArgumentError) do
        Mpp::Methods::Tempo::TempoMethod.new(on_payment_success: hook)
      end

      assert_equal "on_payment_success must be callable", error.message
    end
  end
end

class TestTempoChainPinning < Minitest::Test
  RECIPIENT = "0x0000000000000000000000000000000000000001"
  SIGNED_TX = "0xdeadbeef"

  def stub_account
    Struct.new(:address, :type).new(RECIPIENT, "local")
  end

  def make_method(chain_id:)
    Mpp::Methods::Tempo::TempoMethod.new(account: stub_account, chain_id: chain_id)
  end

  def make_challenge(chain_id: nil)
    request = {
      "amount" => "1000000",
      "currency" => "USD",
      "recipient" => RECIPIENT
    }
    request["methodDetails"] = {"chainId" => chain_id} if chain_id

    Mpp::Challenge.new(
      id: "test-id",
      method: "tempo",
      intent: "charge",
      request: request,
      realm: "test.example.com"
    )
  end

  # The pin check runs before `build_tempo_transfer`, so stubbing it keeps the
  # positive cases deterministic and network-free while still exercising the pin.
  # `source_chain_id` is the chain the transfer reports (used in the DID);
  # `expected_chain_id` is the resolved pin asserted as passed downstream.
  def with_stubbed_transfer(method, source_chain_id:, expected_chain_id:)
    stub = lambda do |*, **kwargs|
      assert_equal expected_chain_id, kwargs[:expected_chain_id]
      [SIGNED_TX, source_chain_id]
    end
    method.stub(:build_tempo_transfer, stub) { yield }
  end

  def test_rejects_conflicting_chain_id
    method = make_method(chain_id: 42_431)
    challenge = make_challenge(chain_id: 1)

    err = assert_raises(Mpp::Methods::Tempo::TransactionError) do
      method.create_credential(challenge)
    end
    assert_equal "Chain ID mismatch: expected 42431, got 1", err.message
  end

  def test_accepts_matching_chain_id
    method = make_method(chain_id: 42_431)
    challenge = make_challenge(chain_id: 42_431)

    credential = with_stubbed_transfer(method, source_chain_id: 42_431, expected_chain_id: 42_431) do
      method.create_credential(challenge)
    end

    assert_equal "did:pkh:eip155:42431:#{RECIPIENT}", credential.source
  end

  def test_accepts_matching_string_pinned_chain_id
    # chain_id may be configured as a String (e.g. from ENV); it should be
    # normalized before comparison so a matching chain is not rejected.
    method = make_method(chain_id: "42431")
    challenge = make_challenge(chain_id: 42_431)

    credential = with_stubbed_transfer(method, source_chain_id: 42_431, expected_chain_id: 42_431) do
      method.create_credential(challenge)
    end

    assert_equal "did:pkh:eip155:42431:#{RECIPIENT}", credential.source
  end

  def test_unpinned_accepts_any_chain_id
    method = make_method(chain_id: nil)
    challenge = make_challenge(chain_id: 1)

    # chain 1 is unknown to CHAIN_RPC_URLS and no pin is set, so no expected
    # chain is enforced downstream; the transfer's reported chain drives the DID.
    credential = with_stubbed_transfer(method, source_chain_id: 1, expected_chain_id: 1) do
      method.create_credential(challenge)
    end

    assert_equal "did:pkh:eip155:1:#{RECIPIENT}", credential.source
  end

  def test_omitted_challenge_chain_id_uses_pin
    method = make_method(chain_id: 42_431)
    challenge = make_challenge(chain_id: nil)

    credential = with_stubbed_transfer(method, source_chain_id: 42_431, expected_chain_id: 42_431) do
      method.create_credential(challenge)
    end

    assert_equal "did:pkh:eip155:42431:#{RECIPIENT}", credential.source
  end

  def test_custom_chain_string_pin_normalizes_downstream
    # Custom chain (not in CHAIN_RPC_URLS) with a String pin: the normalized
    # integer must reach the downstream check so a matching chain is not rejected.
    method = make_method(chain_id: "99999")
    challenge = make_challenge(chain_id: 99_999)

    credential = with_stubbed_transfer(method, source_chain_id: 99_999, expected_chain_id: 99_999) do
      method.create_credential(challenge)
    end

    assert_equal "did:pkh:eip155:99999:#{RECIPIENT}", credential.source
  end
end

class TestTempoClientExtensions < Minitest::Test
  CURRENCY = Mpp::Methods::Tempo::Defaults::PATH_USD
  RECIPIENT = "0x0000000000000000000000000000000000000001"
  ACCOUNT = "0x1234567890abcdef1234567890abcdef12345678"

  class FakeSigner
    attr_reader :address, :hashes

    def initialize(address, byte, parity = 27)
      @address = address
      @signature = byte.chr * 64 + parity.chr
      @hashes = []
    end

    def sign_hash(hash)
      @hashes << hash
      @signature
    end
  end

  class FakeRpc
    attr_reader :calls

    def initialize(chain_id: 42_431)
      @chain_id = chain_id
      @calls = []
    end

    def call(url, method, params)
      @calls << [url, method, params]
      case method
      when "eth_chainId" then "0x#{@chain_id.to_s(16)}"
      when "eth_getTransactionCount" then "0x7"
      when "eth_gasPrice" then "0x2"
      when "eth_estimateGas" then "0x5208"
      when "eth_sendRawTransaction" then "0xtransactionhash"
      end
    end
  end

  class CustomRlp
    attr_reader :encoded, :decoded

    def initialize
      require "rlp"
      @encoded = []
      @decoded = []
    end

    def encode(value)
      @encoded << value
      RLP.encode(value)
    end

    def decode(value)
      @decoded << value
      RLP.decode(value)
    end
  end

  class FakeTransactionFeePayer
    attr_reader :envelopes

    def initialize(result: "0x76c0")
      @result = result
      @envelopes = []
    end

    def cosign(raw_transaction)
      @envelopes << raw_transaction
      @result
    end
  end

  def test_injected_rpc_handles_every_operation_and_preserves_explicit_url
    rpc = FakeRpc.new
    method = build_method(rpc: rpc, rpc_url: "https://internal-rpc.example")

    credential = method.create_credential(challenge, mode: :push)

    assert_equal "hash", credential.payload["type"]
    assert_equal "0xtransactionhash", credential.payload["hash"]
    assert_equal %w[eth_chainId eth_getTransactionCount eth_gasPrice eth_estimateGas eth_sendRawTransaction],
      rpc.calls.map { |call| call[1] }
    assert_equal ["https://internal-rpc.example"], rpc.calls.map(&:first).uniq
  end

  def test_factory_uses_challenge_endpoint_with_custom_provider
    rpc = FakeRpc.new
    method = Mpp::Methods::Tempo.tempo(
      account: FakeSigner.new(ACCOUNT, 0x11),
      intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new},
      rpc: rpc,
      rlp: CustomRlp.new
    )

    method.create_credential(challenge)

    assert_equal [Mpp::Methods::Tempo::Defaults::TESTNET_RPC_URL], rpc.calls.map(&:first).uniq
  end

  def test_factory_requires_rpc_url_for_unknown_configured_chain
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Tempo.tempo(
        account: FakeSigner.new(ACCOUNT, 0x11),
        intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new},
        chain_id: 99_999,
        rpc: FakeRpc.new,
        rlp: CustomRlp.new
      )
    end

    assert_includes error.message, "Pass rpc_url explicitly"
  end

  def test_factory_accepts_explicit_rpc_url_for_unknown_configured_chain
    method = Mpp::Methods::Tempo.tempo(
      account: FakeSigner.new(ACCOUNT, 0x11),
      intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new},
      chain_id: 99_999,
      rpc_url: "https://unknown-chain.internal",
      rpc: FakeRpc.new(chain_id: 99_999),
      rlp: CustomRlp.new
    )

    assert_equal "https://unknown-chain.internal", method.rpc_url
  end

  def test_default_transaction_uses_sequential_nonce_without_validity
    method = build_method
    raw_tx = method.create_credential(challenge).payload["signature"]
    decoded = decode(raw_tx, 0x76)

    assert_equal 0, int_value(decoded[6])
    assert_equal 7, int_value(decoded[7])
    assert_equal "", decoded[8]
  end

  def test_expiring_strategy_uses_max_nonce_key_and_custom_validity
    valid_before = Time.now.to_i + 120
    method = build_method(nonce_strategy: :expiring, valid_before: valid_before)
    decoded = decode(method.create_credential(challenge).payload["signature"], 0x76)

    assert_equal((1 << 256) - 1, int_value(decoded[6]))
    assert_equal 0, int_value(decoded[7])
    assert_equal valid_before, int_value(decoded[8])
  end

  def test_validity_callable_runs_once_per_credential
    calls = []
    resolver = lambda do |challenge:|
      calls << challenge.id
      Time.now.to_i + 120
    end
    method = build_method(nonce_strategy: :expiring, valid_before: resolver)

    2.times { method.create_credential(challenge) }

    assert_equal ["challenge-id", "challenge-id"], calls
  end

  def test_invalid_validity_fails_before_signing
    rpc = FakeRpc.new
    signer = FakeSigner.new(ACCOUNT, 0x11)
    method = build_method(account: signer, rpc: rpc, nonce_strategy: :expiring, valid_before: Time.now.to_i)

    assert_raises(ArgumentError) { method.create_credential(challenge) }
    refute_empty rpc.calls
    assert_empty signer.hashes
  end

  def test_transaction_fee_payer_completes_envelope_without_challenge_flag
    sender = FakeSigner.new(ACCOUNT, 0x11)
    sponsor = FakeTransactionFeePayer.new
    method = build_method(account: sender, transaction_fee_payer: sponsor)

    credential = method.create_credential(challenge)
    decoded = decode(sponsor.envelopes.fetch(0), 0x78)

    assert_equal 1, sender.hashes.length
    assert_equal "0x76c0", credential.payload["signature"]
    assert_equal "", decoded[10]
    assert_equal ACCOUNT.delete_prefix("0x"), decoded[11].unpack1("H*")
    assert_equal 0, int_value(decoded[6])
    assert_equal 7, int_value(decoded[7])
    assert_equal "", decoded[8]
  end

  def test_factory_accepts_transaction_fee_payer
    sponsor = FakeTransactionFeePayer.new
    method = Mpp::Methods::Tempo.tempo(
      account: FakeSigner.new(ACCOUNT, 0x11),
      intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new},
      rpc: FakeRpc.new,
      rlp: CustomRlp.new,
      transaction_fee_payer: sponsor
    )

    assert_equal "0x76c0", method.create_credential(challenge).payload["signature"]
    assert_equal 0x78, raw_bytes(sponsor.envelopes.fetch(0)).getbyte(0)
  end

  def test_transaction_fee_payer_supports_push_mode
    rpc = FakeRpc.new
    sponsor = FakeTransactionFeePayer.new
    method = build_method(rpc: rpc, transaction_fee_payer: sponsor)

    credential = method.create_credential(challenge, mode: :push)

    assert_equal "hash", credential.payload["type"]
    send_call = rpc.calls.find { |call| call[1] == "eth_sendRawTransaction" }
    assert_equal ["0x76c0"], send_call[2]
  end

  def test_server_requested_sponsorship_stays_0x78_and_skips_client_fee_payer
    server_challenge = challenge(fee_payer: true)
    sponsor = FakeTransactionFeePayer.new
    method = build_method(transaction_fee_payer: sponsor)
    raw_tx = method.create_credential(server_challenge).payload["signature"]
    decoded = decode(raw_tx, 0x78)

    assert_equal((1 << 256) - 1, int_value(decoded[6]))
    assert_equal 0, int_value(decoded[7])
    assert_empty sponsor.envelopes
  end

  def test_server_sponsorship_preserves_truthy_fee_payer_compatibility
    assert_equal 0x78,
      raw_bytes(build_method.create_credential(challenge(fee_payer: "true")).payload["signature"]).getbyte(0)
  end

  def test_transaction_fee_payer_does_not_affect_proof_mode
    sponsor = FakeTransactionFeePayer.new
    method = build_method(transaction_fee_payer: sponsor)

    credential = method.create_credential(challenge(fee_payer: true), mode: :proof)

    assert_equal "proof", credential.payload["type"]
    assert_empty method.rpc.calls
    assert_empty sponsor.envelopes
  end

  def test_transaction_fee_payer_must_return_completed_transaction
    method = build_method(transaction_fee_payer: FakeTransactionFeePayer.new(result: "0x78c0"))

    error = assert_raises(Mpp::Methods::Tempo::TransactionError) do
      method.create_credential(challenge)
    end

    assert_includes error.message, "completed 0x76 transaction"
  end

  def test_expiring_ignores_challenge_nonce_key_recommendation
    method = build_method(nonce_strategy: :expiring)
    raw_tx = method.create_credential(challenge(nonce_key: 3)).payload["signature"]
    decoded = decode(raw_tx, 0x76)

    assert_equal((1 << 256) - 1, int_value(decoded[6]))
    assert_equal 0, int_value(decoded[7])
  end

  def test_chain_mismatch_from_injected_rpc_fails_before_signing
    signer = FakeSigner.new(ACCOUNT, 0x11)
    method = build_method(account: signer, rpc: FakeRpc.new(chain_id: 4217))

    error = assert_raises(Mpp::Methods::Tempo::TransactionError) do
      method.create_credential(challenge)
    end
    assert_includes error.message, "RPC returned 4217"
    assert_empty signer.hashes
  end

  def test_factory_validates_provider_signer_and_nonce_shapes
    assert_raises(ArgumentError) { build_method(rpc: Object.new) }
    assert_raises(ArgumentError) { build_method(rlp: Object.new) }
    assert_raises(ArgumentError) { build_method(transaction_fee_payer: Object.new) }
    assert_raises(ArgumentError) { build_method(nonce_strategy: :random) }
  end

  private

  def build_method(account: FakeSigner.new(ACCOUNT, 0x11), rpc: FakeRpc.new, rlp: CustomRlp.new, **options)
    Mpp::Methods::Tempo::TempoMethod.new(
      account: account,
      rpc: rpc,
      rlp: rlp,
      **options
    )
  end

  def challenge(fee_payer: nil, nonce_key: nil)
    details = {"chainId" => 42_431}
    details["feePayer"] = fee_payer unless fee_payer.nil?
    request = {
      "amount" => "1000000",
      "currency" => CURRENCY,
      "recipient" => RECIPIENT,
      "methodDetails" => details
    }
    request["nonce_key"] = nonce_key unless nonce_key.nil?
    Mpp::Challenge.new(
      id: "challenge-id",
      method: "tempo",
      intent: "charge",
      request: request,
      realm: "test.example.com"
    )
  end

  def raw_bytes(raw_tx)
    [raw_tx.delete_prefix("0x")].pack("H*")
  end

  def decode(raw_tx, prefix)
    bytes = raw_bytes(raw_tx)
    assert_equal prefix, bytes.getbyte(0)
    RLP.decode(bytes[1..])
  end

  def int_value(value)
    return value if value.is_a?(Integer)
    return 0 if value.nil? || value == ""

    value.unpack1("H*").to_i(16)
  end
end
