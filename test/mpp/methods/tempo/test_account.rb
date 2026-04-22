# frozen_string_literal: true

require "test_helper"

class TestAccount < Minitest::Test
  # These tests require the eth gem. Skip if not available.
  def test_from_key
    skip "eth gem not available" unless eth_available?

    account = Mpp::Methods::Tempo::Account.from_key(
      "0x4c0883a69102937d6231471b5dbb6204fe512961708279f01a7f7e1df7a8b9e2"
    )

    assert account.address.start_with?("0x")
    assert_equal 42, account.address.length
  end

  def test_sign_hash
    skip "eth gem not available" unless eth_available?

    account = Mpp::Methods::Tempo::Account.from_key(
      "0x4c0883a69102937d6231471b5dbb6204fe512961708279f01a7f7e1df7a8b9e2"
    )
    msg_hash = "\x00" * 32
    sig = account.sign_hash(msg_hash)

    assert_equal 65, sig.bytesize
  end

  def test_sign_hash_rejects_wrong_size
    skip "eth gem not available" unless eth_available?

    account = Mpp::Methods::Tempo::Account.from_key(
      "0x4c0883a69102937d6231471b5dbb6204fe512961708279f01a7f7e1df7a8b9e2"
    )
    assert_raises(ArgumentError) { account.sign_hash("\x00" * 16) }
  end

  def test_from_env
    skip "eth gem not available" unless eth_available?

    begin
      ENV["TEST_TEMPO_KEY"] = "0x4c0883a69102937d6231471b5dbb6204fe512961708279f01a7f7e1df7a8b9e2"
      account = Mpp::Methods::Tempo::Account.from_env("TEST_TEMPO_KEY")

      assert account.address.start_with?("0x")
    ensure
      ENV.delete("TEST_TEMPO_KEY")
    end
  end

  def test_from_env_raises_when_missing
    ENV.delete("NONEXISTENT_KEY")
    assert_raises(ArgumentError) { Mpp::Methods::Tempo::Account.from_env("NONEXISTENT_KEY") }
  end

  private

  def eth_available?
    require "eth"
    true
  rescue LoadError
    false
  end
end
