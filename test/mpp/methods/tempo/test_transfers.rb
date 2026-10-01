# frozen_string_literal: true

require "test_helper"

class TestTempoTransfers < Minitest::Test
  RECIPIENT = "0x0000000000000000000000000000000000000001"
  SPLIT_RECIPIENT = "0x#{"02" * 20}"

  def test_resolves_primary_remainder_and_splits_like_mppx
    transfers = Mpp::Methods::Tempo::Transfers.resolve(
      amount: "100",
      recipient: RECIPIENT,
      memo: "0xprimary",
      splits: [{"amount" => "30", "recipient" => SPLIT_RECIPIENT, "memo" => "0x#{"11" * 32}"}]
    )

    assert_equal [70, 30], transfers.map(&:amount)
    assert_equal [RECIPIENT, SPLIT_RECIPIENT], transfers.map(&:recipient)
    assert_equal ["0xprimary", "0x#{"11" * 32}"], transfers.map(&:memo)
  end

  def test_rejects_invalid_split_shapes
    assert_raises(ArgumentError) do
      Mpp::Methods::Tempo::Transfers.resolve(amount: "100", recipient: RECIPIENT, splits: [])
    end
    assert_raises(ArgumentError) do
      Mpp::Methods::Tempo::Transfers.resolve(
        amount: "100",
        recipient: RECIPIENT,
        splits: [{"amount" => "1", "recipient" => "not-hex"}]
      )
    end
    assert_raises(ArgumentError) do
      Mpp::Methods::Tempo::Transfers.resolve(
        amount: "100",
        recipient: RECIPIENT,
        splits: [{"amount" => "0", "recipient" => SPLIT_RECIPIENT}]
      )
    end
    assert_raises(ArgumentError) do
      Mpp::Methods::Tempo::Transfers.resolve(
        amount: "100",
        recipient: RECIPIENT,
        splits: [{"amount" => "100", "recipient" => SPLIT_RECIPIENT}]
      )
    end
    assert_raises(ArgumentError) do
      Mpp::Methods::Tempo::Transfers.resolve(
        amount: "100",
        recipient: RECIPIENT,
        splits: Array.new(11) { {"amount" => "1", "recipient" => SPLIT_RECIPIENT} }
      )
    end
  end
end
