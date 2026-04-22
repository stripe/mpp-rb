# frozen_string_literal: true

require "test_helper"

class TestAttribution < Minitest::Test
  def test_encode_returns_66_char_hex_string
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server")

    assert_equal 66, memo.length
    assert memo.start_with?("0x")
  end

  def test_is_mpp_memo
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server")

    assert Mpp::Methods::Tempo::Attribution.mpp_memo?(memo)
  end

  def test_not_mpp_memo
    refute Mpp::Methods::Tempo::Attribution.mpp_memo?("0x#{"00" * 32}")
  end

  def test_verify_server
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server")

    assert Mpp::Methods::Tempo::Attribution.verify_server(memo, "test-server")
  end

  def test_verify_server_wrong_id
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server")

    refute Mpp::Methods::Tempo::Attribution.verify_server(memo, "other-server")
  end

  def test_encode_with_client_id
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server", client_id: "test-client")

    assert Mpp::Methods::Tempo::Attribution.mpp_memo?(memo)
  end

  def test_decode_roundtrip
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server", client_id: "test-client")
    decoded = Mpp::Methods::Tempo::Attribution.decode(memo)

    refute_nil decoded
    assert_equal 1, decoded.version
    assert decoded.server_fingerprint.start_with?("0x")
    assert_equal 22, decoded.server_fingerprint.length
    refute_nil decoded.client_fingerprint
    assert decoded.client_fingerprint.start_with?("0x")
    assert_equal 22, decoded.client_fingerprint.length
    assert decoded.nonce.start_with?("0x")
  end

  def test_decode_without_client
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server")
    decoded = Mpp::Methods::Tempo::Attribution.decode(memo)

    refute_nil decoded
    assert_nil decoded.client_fingerprint
  end

  def test_decode_invalid_memo
    assert_nil Mpp::Methods::Tempo::Attribution.decode("0x#{"00" * 32}")
  end

  def test_different_server_ids_produce_different_fingerprints
    m1 = Mpp::Methods::Tempo::Attribution.encode(server_id: "server-a")
    m2 = Mpp::Methods::Tempo::Attribution.encode(server_id: "server-b")
    d1 = Mpp::Methods::Tempo::Attribution.decode(m1)
    d2 = Mpp::Methods::Tempo::Attribution.decode(m2)

    refute_equal d1.server_fingerprint, d2.server_fingerprint
  end

  def test_wrong_length_not_mpp_memo
    refute Mpp::Methods::Tempo::Attribution.mpp_memo?("0x1234")
    refute Mpp::Methods::Tempo::Attribution.mpp_memo?("")
  end

  def test_encode_with_challenge_id_deterministic
    m1 = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server", challenge_id: "chal-123")
    m2 = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server", challenge_id: "chal-123")

    d1 = Mpp::Methods::Tempo::Attribution.decode(m1)
    d2 = Mpp::Methods::Tempo::Attribution.decode(m2)

    assert_equal d1.nonce, d2.nonce
  end

  def test_encode_with_different_challenge_ids
    m1 = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server", challenge_id: "chal-a")
    m2 = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server", challenge_id: "chal-b")

    d1 = Mpp::Methods::Tempo::Attribution.decode(m1)
    d2 = Mpp::Methods::Tempo::Attribution.decode(m2)

    refute_equal d1.nonce, d2.nonce
  end

  def test_encode_without_challenge_id_is_random
    m1 = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server")
    m2 = Mpp::Methods::Tempo::Attribution.encode(server_id: "test-server")

    d1 = Mpp::Methods::Tempo::Attribution.decode(m1)
    d2 = Mpp::Methods::Tempo::Attribution.decode(m2)

    # Random nonces should (almost certainly) differ
    refute_equal d1.nonce, d2.nonce
  end
end
