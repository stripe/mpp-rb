# frozen_string_literal: true

require "test_helper"

class TestExpires < Minitest::Test
  def test_seconds_format
    result = Mpp::Expires.seconds(60)

    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, result)
  end

  def test_minutes_format
    result = Mpp::Expires.minutes(5)

    assert_match(/Z\z/, result)
  end

  def test_hours_format
    result = Mpp::Expires.hours(1)

    assert_match(/Z\z/, result)
  end

  def test_days_format
    result = Mpp::Expires.days(1)

    assert_match(/Z\z/, result)
  end

  def test_seconds_is_future
    before = Time.now.utc
    result = Mpp::Expires.seconds(300)
    parsed = Time.iso8601(result)

    assert_operator parsed, :>, before
  end

  def test_weeks
    result = Mpp::Expires.weeks(1)
    parsed = Time.iso8601(result)

    assert_operator parsed, :>, Time.now.utc
  end

  def test_months
    result = Mpp::Expires.months(1)
    parsed = Time.iso8601(result)

    assert_operator parsed, :>, Time.now.utc
  end

  def test_years
    result = Mpp::Expires.years(1)
    parsed = Time.iso8601(result)

    assert_operator parsed, :>, Time.now.utc
  end
end
