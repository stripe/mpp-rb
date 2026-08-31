# frozen_string_literal: true

require "test_helper"

class TestFeePayerPolicy < Minitest::Test
  Policy = Mpp::Methods::Tempo::FeePayerPolicy
  Defaults = Mpp::Methods::Tempo::Defaults

  def test_mainnet_uses_default_policy
    policy = Policy.for_chain_id(Defaults::CHAIN_ID)
    assert_equal Policy::DEFAULT, policy,
      "Mainnet (chain_id=#{Defaults::CHAIN_ID}) should use the DEFAULT (stricter) policy"
  end

  def test_testnet_uses_testnet_policy
    policy = Policy.for_chain_id(Defaults::TESTNET_CHAIN_ID)
    assert_equal Policy::TESTNET, policy,
      "Testnet (chain_id=#{Defaults::TESTNET_CHAIN_ID}) should use the TESTNET (relaxed) policy"
  end

  def test_unknown_chain_uses_default_policy
    policy = Policy.for_chain_id(99999)
    assert_equal Policy::DEFAULT, policy,
      "Unknown chain IDs should fall back to the DEFAULT policy"
  end

  def test_testnet_has_higher_max_priority_fee
    assert_operator Policy::TESTNET.max_priority_fee_per_gas, :>,
      Policy::DEFAULT.max_priority_fee_per_gas,
      "TESTNET policy should have a higher max_priority_fee_per_gas than DEFAULT"
  end
end
