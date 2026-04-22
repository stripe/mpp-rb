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

  private

  def rlp_available?
    require "rlp"
    true
  rescue LoadError
    false
  end
end
