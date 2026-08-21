# frozen_string_literal: true

require "test_helper"

class TestEvmAuthorization < Minitest::Test
  def test_keccak256_empty_string
    assert_equal(
      "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
      Mpp::Methods::Evm::Keccak.hexdigest("")
    )
  end

  def test_keccak256_abc
    assert_equal(
      "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45",
      Mpp::Methods::Evm::Keccak.hexdigest("abc")
    )
  end

  def test_challenge_hash_is_keccak_of_id_and_realm
    challenge = Mpp::Challenge.create(
      secret_key: "secret",
      realm: "api.example.com",
      method: "evm",
      intent: "charge",
      request: {"amount" => "1"}
    )
    digest = Mpp::Methods::Evm::Authorization.challenge_hash(challenge)

    assert_match(/\A0x[a-f0-9]{64}\z/, digest)
    expected = Mpp::Methods::Evm::Keccak.digest("#{challenge.id}#{challenge.realm}")
    assert_equal "0x#{expected.unpack1("H*")}", digest
  end

  def test_checksum_address_round_trips_known_usdc
    address = Mpp::Methods::Evm::Assets::BASE_USDC.address
    checksummed = Mpp::Methods::Evm::Authorization.checksum_address(address.downcase)

    assert_equal address, checksummed
    refute_equal address.downcase, checksummed
  end
end
