# frozen_string_literal: true

require "test_helper"

class TestKeychain < Minitest::Test
  def test_signature_constants
    assert_equal 0x03, Mpp::Methods::Tempo::Keychain::SIGNATURE_TYPE
    assert_equal 86, Mpp::Methods::Tempo::Keychain::SIGNATURE_LENGTH
  end
end
