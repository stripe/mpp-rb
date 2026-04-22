# frozen_string_literal: true

require "test_helper"

class TestUnits < Minitest::Test
  def test_parse_units_integer
    assert_equal 1_000_000, Mpp::Units.parse_units("1", 6)
  end

  def test_parse_units_decimal
    assert_equal 1_500_000, Mpp::Units.parse_units("1.5", 6)
  end

  def test_parse_units_small
    assert_equal 25, Mpp::Units.parse_units("0.000025", 6)
  end

  def test_parse_units_zero
    assert_equal 0, Mpp::Units.parse_units("0", 6)
  end

  def test_parse_units_zero_decimal
    assert_equal 0, Mpp::Units.parse_units("0.000000", 6)
  end

  def test_parse_units_rejects_empty
    assert_raises(ArgumentError) { Mpp::Units.parse_units("", 6) }
  end

  def test_parse_units_rejects_negative
    assert_raises(ArgumentError) { Mpp::Units.parse_units("-1", 6) }
  end

  def test_parse_units_rejects_non_string
    assert_raises(ArgumentError) { Mpp::Units.parse_units(123, 6) }
  end

  def test_parse_units_rejects_fractional_base_units
    assert_raises(ArgumentError) { Mpp::Units.parse_units("1.1234567", 6) }
  end

  def test_parse_units_rejects_invalid
    assert_raises(ArgumentError) { Mpp::Units.parse_units("abc", 6) }
  end

  def test_transform_units_with_decimals
    request = {"amount" => "1.5", "decimals" => 6}
    result = Mpp::Units.transform_units(request)

    assert_equal "1500000", result["amount"]
    refute result.key?("decimals")
  end

  def test_transform_units_without_decimals
    request = {"amount" => "1000000"}
    result = Mpp::Units.transform_units(request)

    assert_equal "1000000", result["amount"]
  end

  def test_transform_units_with_suggested_deposit
    request = {"amount" => "1.0", "suggestedDeposit" => "10.0", "decimals" => 6}
    result = Mpp::Units.transform_units(request)

    assert_equal "1000000", result["amount"]
    assert_equal "10000000", result["suggestedDeposit"]
  end

  def test_transform_units_rejects_non_integer_decimals
    request = {"amount" => "1.0", "decimals" => "six"}
    assert_raises(ArgumentError) { Mpp::Units.transform_units(request) }
  end
end
