# frozen_string_literal: true

require "test_helper"

class TestTempoFeePayerPolicy < Minitest::Test
  Defaults = Mpp::Methods::Tempo::Defaults
  Policy = Mpp::Methods::Tempo::FeePayerPolicy

  def test_uses_default_policy_for_mainnet
    assert_same Policy::DEFAULT, Policy.for_chain_id(Defaults::CHAIN_ID)
  end

  def test_uses_testnet_policy_for_testnet
    assert_same Policy::TESTNET, Policy.for_chain_id(Defaults::TESTNET_CHAIN_ID)
  end

  def test_uses_default_policy_for_unknown_chains
    assert_same Policy::DEFAULT, Policy.for_chain_id(99_999)
  end
end
