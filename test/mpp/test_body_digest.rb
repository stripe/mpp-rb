# frozen_string_literal: true

require "test_helper"

class TestBodyDigest < Minitest::Test
  def test_compute_empty_string
    result = Mpp::BodyDigest.compute("")

    assert_equal "sha-256=47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", result
  end

  def test_compute_string
    result = Mpp::BodyDigest.compute("hello world")

    assert result.start_with?("sha-256=")
  end

  def test_compute_dict
    result = Mpp::BodyDigest.compute({"key" => "value"})

    assert result.start_with?("sha-256=")
  end

  def test_verify_roundtrip
    body = "test body content"
    digest = Mpp::BodyDigest.compute(body)

    assert Mpp::BodyDigest.verify(digest, body)
  end

  def test_verify_wrong_body
    digest = Mpp::BodyDigest.compute("original")

    refute Mpp::BodyDigest.verify(digest, "tampered")
  end

  def test_verify_dict_roundtrip
    body = {"amount" => "1000", "currency" => "USD"}
    digest = Mpp::BodyDigest.compute(body)

    assert Mpp::BodyDigest.verify(digest, body)
  end

  def test_deterministic_dict_encoding
    d1 = Mpp::BodyDigest.compute({"b" => "2", "a" => "1"})
    d2 = Mpp::BodyDigest.compute({"a" => "1", "b" => "2"})

    assert_equal d1, d2
  end
end
