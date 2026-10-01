# frozen_string_literal: true

require "test_helper"

class TestFeePayer < Minitest::Test
  def test_type_id_constant
    assert_equal 0x78, Mpp::Methods::Tempo::FeePayer::TYPE_ID
  end

  def test_decode_rejects_non_0x78_prefix
    skip "rlp gem not available" unless rlp_available?

    assert_raises(ArgumentError) do
      Mpp::Methods::Tempo::FeePayer.decode("\x77\x00".b)
    end
  end

  def test_custom_codec_is_used_for_encode_and_decode
    skip "rlp gem not available" unless rlp_available?
    codec = Struct.new(:encode_calls, :decode_calls) do
      def encode(value)
        self.encode_calls += 1
        RLP.encode(value)
      end

      def decode(value)
        self.decode_calls += 1
        RLP.decode(value)
      end
    end.new(0, 0)
    tx = Mpp::Methods::Tempo::Transaction::SignedTransaction.new(
      chain_id: 42_431,
      max_priority_fee_per_gas: 1,
      max_fee_per_gas: 1,
      gas_limit: 1_000_000,
      calls: [],
      access_list: [],
      nonce_key: (1 << 256) - 1,
      nonce: 0,
      valid_before: Time.now.to_i + 60,
      valid_after: nil,
      fee_token: nil,
      sender_signature: "\x11" * 64 + "\x1b",
      fee_payer_signature: Mpp::Methods::Tempo::Transaction::EMPTY_SIGNATURE,
      sender_address: "0x#{"12" * 20}",
      tempo_authorization_list: [],
      key_authorization: nil
    )

    encoded = Mpp::Methods::Tempo::FeePayer.encode(tx, rlp: codec)
    Mpp::Methods::Tempo::FeePayer.decode(encoded, rlp: codec)

    assert_equal 1, codec.encode_calls
    assert_equal 1, codec.decode_calls
  end

  private

  def rlp_available?
    require "rlp"
    true
  rescue LoadError
    false
  end
end
