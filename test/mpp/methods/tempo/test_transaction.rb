# frozen_string_literal: true

require "test_helper"

class TestTempoTransaction < Minitest::Test
  FakeAccount = Struct.new(:address, :signature) do
    def sign_hash(_digest)
      signature || ("\x33" * 64 + "\x1b")
    end
  end

  CURRENCY = "0x20c0000000000000000000000000000000000000"
  RECIPIENT = "0x742d35Cc6634c0532925a3b844bC9e7595F8fE00"
  ACCOUNT = "0x1234567890abcdef1234567890abcdef12345678"

  def test_build_signed_transfer_requires_eth_and_rlp
    original_require = Kernel.method(:require)
    Kernel.stub(:require, lambda { |name|
      raise LoadError, "cannot load such file -- #{name}" if %w[eth rlp].include?(name)

      original_require.call(name)
    }) do
      error = assert_raises(LoadError) do
        Mpp::Methods::Tempo::Transaction.build_signed_transfer(
          account: FakeAccount.new("0x1234567890abcdef1234567890abcdef12345678"),
          chain_id: 42_431,
          gas_limit: 1_000_000,
          gas_price: 1,
          nonce: 0,
          nonce_key: 0,
          currency: CURRENCY,
          transfer_data: "0xa9059cbb" + ("0" * 128),
          awaiting_fee_payer: false
        )
      end

      assert_includes error.message, "eth gem"
    end
  end

  def test_signed_transfer_places_sender_signature_in_final_envelope
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    raw_tx, chain_id = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: FakeAccount.new(ACCOUNT, "\x11" * 64 + "\x1b"),
      chain_id: 42_431,
      gas_limit: 1_000_000,
      gas_price: 1,
      nonce: 0,
      nonce_key: 0,
      currency: CURRENCY,
      transfer_data: transfer_data,
      awaiting_fee_payer: false
    )

    assert_equal 42_431, chain_id
    decoded = decode_raw_tx(raw_tx, 0x76)

    assert_equal 14, decoded.length
    assert_equal CURRENCY.downcase.delete_prefix("0x"), decoded[10].unpack1("H*")
    assert_equal "", decoded[11]
    assert_equal [], decoded[12]
    assert_equal "\x11" * 64 + "\x00", decoded[13]
  end

  def test_awaiting_fee_payer_builds_decodable_0x78_envelope
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    raw_tx, = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: FakeAccount.new(ACCOUNT, "\x22" * 64 + "\x1c"),
      chain_id: 42_431,
      gas_limit: 1_000_000,
      gas_price: 1,
      nonce: 0,
      nonce_key: (1 << 256) - 1,
      currency: CURRENCY,
      transfer_data: transfer_data,
      valid_before: 9_999_999_999,
      awaiting_fee_payer: true
    )

    decoded = decode_raw_tx(raw_tx, 0x78)

    assert_equal 14, decoded.length
    assert_equal "", decoded[10]
    assert_equal ACCOUNT.downcase.delete_prefix("0x"), decoded[11].unpack1("H*")
    assert_equal [], decoded[12]
    assert_equal "\x22" * 64 + "\x01", decoded[13]
  end

  def test_fee_payer_signature_encodes_as_tuple_in_field_11
    skip "rlp gem not available" unless rlp_available?

    tx = Mpp::Methods::Tempo::Transaction::SignedTransaction.new(
      chain_id: 42_431,
      max_priority_fee_per_gas: 1,
      max_fee_per_gas: 1,
      gas_limit: 1_000_000,
      calls: [Mpp::Methods::Tempo::Transaction::Call.new(to: CURRENCY, value: 0, data: transfer_data)],
      access_list: [],
      nonce_key: 0,
      nonce: 0,
      valid_before: nil,
      valid_after: nil,
      fee_token: CURRENCY,
      sender_signature: "\x44" * 64 + "\x1b",
      fee_payer_signature: "\x55" * 64 + "\x1c",
      sender_address: ACCOUNT,
      tempo_authorization_list: [],
      key_authorization: nil
    )

    decoded = RLP.decode(tx.encoded_2718[1..])

    assert_equal 14, decoded.length
    assert_equal ["\x01", "\x55" * 32, "\x55" * 32], decoded[11]
    assert_equal [], decoded[12]
    assert_equal "\x44" * 64 + "\x00", decoded[13]
  end

  def test_charge_intent_cosigns_awaiting_fee_payer_envelope
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    payer = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    fee_payer = Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
    raw_tx, = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: payer,
      chain_id: 42_431,
      gas_limit: 1_000_000,
      gas_price: 1,
      nonce: 0,
      nonce_key: (1 << 256) - 1,
      currency: CURRENCY,
      transfer_data: transfer_data,
      valid_before: Time.now.to_i + 60,
      awaiting_fee_payer: true
    )
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, fee_payer: fee_payer)

    signed_raw = intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY)
    decoded = decode_raw_tx(signed_raw, 0x76)

    assert_equal CURRENCY.downcase.delete_prefix("0x"), decoded[10].unpack1("H*")
    assert_equal 3, decoded[11].length
    assert_equal 65, decoded[13].bytesize
  end

  def test_charge_intent_cosigns_fee_payer_envelope_with_access_list
    skip "eth/rlp gems not available" unless eth_and_rlp_available?

    payer = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    fee_payer = Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
    access_list = [[pack_hex(CURRENCY), [pack_hex("0x#{"00" * 32}")]]]
    tx = Mpp::Methods::Tempo::Transaction::SignedTransaction.new(
      chain_id: 42_431,
      max_priority_fee_per_gas: 1,
      max_fee_per_gas: 1,
      gas_limit: 1_000_000,
      calls: [Mpp::Methods::Tempo::Transaction::Call.new(to: CURRENCY, value: 0, data: transfer_data)],
      access_list: access_list,
      nonce_key: (1 << 256) - 1,
      nonce: 0,
      valid_before: Time.now.to_i + 60,
      valid_after: nil,
      fee_token: nil,
      sender_signature: nil,
      fee_payer_signature: Mpp::Methods::Tempo::Transaction::EMPTY_SIGNATURE,
      sender_address: payer.address,
      tempo_authorization_list: [],
      key_authorization: nil
    )
    sender_signature = payer.sign_hash(tx.signature_hash)
    raw_tx = "0x#{Mpp::Methods::Tempo::FeePayer.encode(tx.with(sender_signature: sender_signature)).unpack1("H*")}"
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, fee_payer: fee_payer)

    signed_raw = intent.send(:cosign_as_fee_payer, raw_tx, CURRENCY)
    decoded = decode_raw_tx(signed_raw, 0x76)

    assert_equal access_list, decoded[5]
    assert_equal 3, decoded[11].length
    assert_equal 65, decoded[13].bytesize
  end

  private

  def transfer_data
    to_padded = RECIPIENT.delete_prefix("0x").downcase.rjust(64, "0")
    amount_padded = 1_000_000.to_s(16).rjust(64, "0")
    "0xa9059cbb#{to_padded}#{amount_padded}"
  end

  def decode_raw_tx(raw_tx, prefix)
    bytes = [raw_tx.delete_prefix("0x")].pack("H*")

    assert_equal prefix, bytes.getbyte(0)
    RLP.decode(bytes[1..])
  end

  def pack_hex(value)
    [value.delete_prefix("0x")].pack("H*")
  end

  def eth_and_rlp_available?
    require "eth"
    rlp_available?
  rescue LoadError
    false
  end

  def rlp_available?
    require "rlp"
    true
  rescue LoadError
    false
  end
end
