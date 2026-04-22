# frozen_string_literal: true

require "test_helper"

class TestTempoTransaction < Minitest::Test
  FakeAccount = Struct.new(:address) do
    def sign_hash(_digest)
      "\x33" * 65
    end
  end

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
          currency: Mpp::Methods::Tempo::Defaults::PATH_USD,
          transfer_data: "0xa9059cbb" + ("0" * 128),
          awaiting_fee_payer: false
        )
      end

      assert_includes error.message, "eth gem"
    end
  end
end
