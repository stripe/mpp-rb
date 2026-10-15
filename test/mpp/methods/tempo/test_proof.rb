# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

# Tests for EIP-712 Tempo proof credentials (zero-amount wallet-ownership proofs).
# The signed typed data binds both the challenge id AND the server realm, and the
# wallet is bound via the recovered signer matching the credential source address.
class TestTempoProof < Minitest::Test
  Proof = Mpp::Methods::Tempo::Proof

  # Well-known test private keys (deterministic addresses).
  KEY_A = "0x4c0883a69102937d6231471b5dbb6204fe512961708279f01a7f7e1df7a8b9e2"
  KEY_B = "0x4646464646464646464646464646464646464646464646464646464646464646"

  CHAIN_ID = 1
  CHALLENGE_ID = "ch_test_123"
  REALM = "api.example.com"

  def setup
    @eth_available = begin
      require "eth"
      true
    rescue LoadError
      false
    end
  end

  def account(key)
    Mpp::Methods::Tempo::Account.from_key(key)
  end

  # --- ABI conformance (the create-intent/challenge ABI fixture) ---

  def test_domain_version_is_3
    assert_equal "3", Proof::DOMAIN_VERSION
  end

  def test_proof_type_hash_binds_account_challenge_id_and_realm
    assert_equal "Proof(address account,string challengeId,string realm)", Proof::PROOF_TYPE_HASH
  end

  # Shared vector, pinned identically in mpp-go (proof_vectors_test.go),
  # mpp-rs (test_signing_hash_matches_mppx_v3_vector) and mppx
  # (Proof.conformance.test.ts). If this drifts, mpp-rb has silently stopped
  # interoperating with the other SDKs.
  def test_signing_hash_matches_cross_sdk_vector
    skip "eth gem not available" unless @eth_available

    hash = Proof.signing_hash(
      chain_id: 42431,
      account: "0x1a642f0E3c3aF545E7AcBD38b07251B3990914F1",
      challenge_id: "kM9xPqWvT2nJrHsY4aDfEb",
      realm: "api.example.com"
    )

    assert_equal "0x3860a700a55e02ad3c2dc047e92489feceecbdb0a801d948e1d9f0b61ea9bc3f",
      "0x#{hash.unpack1("H*")}"
  end

  # A signature over the old v2 digest (domain version "2", no account field)
  # must not verify under v3. mppx pins the same negative case.
  def test_rejects_legacy_v2_proof
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    legacy_domain = Proof.keccak256(
      Proof.abi_encode(
        Proof.keccak256(Proof::DOMAIN_TYPE_HASH),
        Proof.keccak256("MPP"),
        Proof.keccak256("2"),
        Proof.uint256(CHAIN_ID)
      )
    )
    legacy_struct = Proof.keccak256(
      Proof.abi_encode(
        Proof.keccak256("Proof(string challengeId,string realm)"),
        Proof.keccak256(CHALLENGE_ID),
        Proof.keccak256(REALM)
      )
    )
    legacy_hash = Proof.keccak256("\x19\x01".b + legacy_domain + legacy_struct)
    legacy_sig = "0x#{acct.sign_hash(legacy_hash).unpack1("H*")}"

    refute Proof.verify(
      address: acct.address.to_s,
      chain_id: CHAIN_ID,
      challenge_id: CHALLENGE_ID,
      realm: REALM,
      signature: legacy_sig
    )
  end

  # The signature commits to one payer, so it cannot be presented as a proof
  # for a different account.
  def test_proof_does_not_transfer_to_another_account
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    other = account(KEY_B)
    sig = Proof.sign(account: acct, chain_id: CHAIN_ID, challenge_id: CHALLENGE_ID, realm: REALM)

    assert Proof.verify(address: acct.address.to_s, chain_id: CHAIN_ID,
      challenge_id: CHALLENGE_ID, realm: REALM, signature: sig)
    refute Proof.verify(address: other.address.to_s, chain_id: CHAIN_ID,
      challenge_id: CHALLENGE_ID, realm: REALM, signature: sig)
  end

  # --- source DID (wallet binding carrier) ---

  def test_source_did_construction
    source = Proof.source(address: "0xAbC0000000000000000000000000000000000001", chain_id: 8453)
    assert_equal "did:pkh:eip155:8453:0xAbC0000000000000000000000000000000000001", source
  end

  def test_parse_source_valid
    parsed = Proof.parse_source("did:pkh:eip155:1:0xAbC0000000000000000000000000000000000001")
    assert_equal 1, parsed[:chain_id]
    assert_equal "0xAbC0000000000000000000000000000000000001", parsed[:address]
  end

  def test_parse_source_rejects_malformed
    assert_nil Proof.parse_source("not-a-did")
    assert_nil Proof.parse_source("did:pkh:eip155:1:0xshort")
    assert_nil Proof.parse_source("did:pkh:eip155:01:0xAbC0000000000000000000000000000000000001")
    assert_nil Proof.parse_source("did:pkh:other:1:0xAbC0000000000000000000000000000000000001")
  end

  # --- sign / verify round trip ---

  def test_sign_verify_round_trip
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: CHAIN_ID, challenge_id: CHALLENGE_ID, realm: REALM)

    assert Proof.verify(
      address: acct.address,
      chain_id: CHAIN_ID,
      challenge_id: CHALLENGE_ID,
      realm: REALM,
      signature: sig
    )
  end

  # --- realm binding ---

  def test_verify_rejects_realm_mismatch
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: CHAIN_ID, challenge_id: CHALLENGE_ID, realm: REALM)

    refute Proof.verify(
      address: acct.address,
      chain_id: CHAIN_ID,
      challenge_id: CHALLENGE_ID,
      realm: "evil.example.com",
      signature: sig
    )
  end

  # --- wallet binding ---

  def test_verify_rejects_wrong_address
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    other = account(KEY_B)
    sig = Proof.sign(account: acct, chain_id: CHAIN_ID, challenge_id: CHALLENGE_ID, realm: REALM)

    refute Proof.verify(
      address: other.address,
      chain_id: CHAIN_ID,
      challenge_id: CHALLENGE_ID,
      realm: REALM,
      signature: sig
    )
  end

  # --- challenge id binding ---

  def test_verify_rejects_challenge_id_mismatch
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: CHAIN_ID, challenge_id: CHALLENGE_ID, realm: REALM)

    refute Proof.verify(
      address: acct.address,
      chain_id: CHAIN_ID,
      challenge_id: "ch_other",
      realm: REALM,
      signature: sig
    )
  end

  # --- chain id binding ---

  def test_verify_rejects_chain_id_mismatch
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: CHAIN_ID, challenge_id: CHALLENGE_ID, realm: REALM)

    refute Proof.verify(
      address: acct.address,
      chain_id: 999,
      challenge_id: CHALLENGE_ID,
      realm: REALM,
      signature: sig
    )
  end

  # --- uint256 encoding (domain chainId) regression ---

  def test_uint256_handles_values_above_64_bits
    skip "eth gem not available" unless @eth_available

    # A chain id larger than 2**64 must not silently truncate; sign/verify must round-trip.
    big_chain = (1 << 200) + 7
    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: big_chain, challenge_id: CHALLENGE_ID, realm: REALM)

    assert Proof.verify(address: acct.address, chain_id: big_chain, challenge_id: CHALLENGE_ID, realm: REALM, signature: sig)
    refute Proof.verify(address: acct.address, chain_id: big_chain + 1, challenge_id: CHALLENGE_ID, realm: REALM, signature: sig)
  end

  # --- server-side verify path (ChargeIntent#verify -> verify_proof) ---

  def server_proof_credential(realm:, signed_realm:, chain_id: 4217, challenge_id: "ch_srv_1")
    acct = account(KEY_A)
    sig = Proof.sign(account: acct, chain_id: chain_id, challenge_id: challenge_id, realm: signed_realm)
    Mpp::Credential.new(
      challenge: Mpp::ChallengeEcho.new(
        id: challenge_id, realm: realm, method: "tempo", intent: "charge", request: ""
      ),
      payload: {"type" => "proof", "signature" => sig},
      source: Proof.source(address: acct.address, chain_id: chain_id)
    )
  end

  def zero_amount_request
    {"amount" => "0", "currency" => "0x00", "recipient" => "0x01"}
  end

  def test_server_verify_proof_round_trip
    skip "eth gem not available" unless @eth_available

    intent = Mpp::Methods::Tempo::ChargeIntent.new
    credential = server_proof_credential(realm: REALM, signed_realm: REALM)

    receipt = intent.verify(credential, zero_amount_request)
    assert_equal "ch_srv_1", receipt.reference
  end

  def test_server_verify_proof_rejects_realm_mismatch
    skip "eth gem not available" unless @eth_available

    intent = Mpp::Methods::Tempo::ChargeIntent.new
    # Signed for a different realm than the challenge echo claims.
    credential = server_proof_credential(realm: REALM, signed_realm: "evil.example.com")

    err = assert_raises(Mpp::VerificationError) do
      intent.verify(credential, zero_amount_request)
    end
    assert_match(/does not match source/, err.message)
  end

  def test_server_verify_proof_rejects_nonzero_amount
    skip "eth gem not available" unless @eth_available

    intent = Mpp::Methods::Tempo::ChargeIntent.new
    credential = server_proof_credential(realm: REALM, signed_realm: REALM)

    err = assert_raises(Mpp::VerificationError) do
      intent.verify(credential, {"amount" => "100", "currency" => "0x00", "recipient" => "0x01"})
    end
    assert_match(/zero-amount/, err.message)
  end

  # --- end-to-end through the client method (proves realm wiring) ---

  def test_client_create_credential_proof_mode_binds_realm
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    method = Mpp::Methods::Tempo::TempoMethod.new(account: acct, chain_id: CHAIN_ID)

    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: {"amount" => "0", "currency" => "0x00", "recipient" => "0x01", "methodDetails" => {}},
      expires: (Time.now.utc + 300).strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    )

    credential = method.create_credential(challenge, mode: :proof)

    assert_equal "proof", credential.payload["type"]
    source = Proof.parse_source(credential.source)
    assert_equal acct.address.downcase, source[:address].downcase

    # Verifies only with the real challenge realm, not a forged one.
    assert Proof.verify(
      address: source[:address],
      chain_id: CHAIN_ID,
      challenge_id: challenge.id,
      realm: challenge.realm,
      signature: credential.payload["signature"]
    )
    refute Proof.verify(
      address: source[:address],
      chain_id: CHAIN_ID,
      challenge_id: challenge.id,
      realm: "evil.example.com",
      signature: credential.payload["signature"]
    )
  end

  def test_automatically_signs_zero_amount_proofs_without_rpc
    skip "eth gem not available" unless @eth_available

    acct = account(KEY_A)
    [nil, :pull, :push, :proof].each do |mode|
      [4217, 42431, 12345].each do |chain_id|
        method = Mpp::Methods::Tempo::TempoMethod.new(account: acct)
        challenge = automatic_challenge(amount: "0", chain_id: chain_id)

        credential = method.create_credential(challenge, mode: mode)

        assert_equal "proof", credential.payload["type"]
        assert Proof.verify(address: acct.address, chain_id: chain_id,
          challenge_id: challenge.id, realm: challenge.realm,
          signature: credential.payload["signature"])
      end
    end
    assert_not_requested(:post, %r{https?://})
  end

  def test_automatic_proof_preserves_chain_pin
    skip "eth gem not available" unless @eth_available

    method = Mpp::Methods::Tempo::TempoMethod.new(account: account(KEY_A), chain_id: 4217)
    credential = method.create_credential(automatic_challenge(amount: "0", chain_id: nil))
    assert_equal 4217, Proof.parse_source(credential.source)[:chain_id]

    assert_raises(Mpp::Methods::Tempo::TransactionError) do
      method.create_credential(automatic_challenge(amount: "0", chain_id: 42431))
    end
    assert_not_requested(:post, %r{https?://})
  end

  def test_automatic_proof_requires_chain_id
    skip "eth gem not available" unless @eth_available

    method = Mpp::Methods::Tempo::TempoMethod.new(account: account(KEY_A))
    assert_raises(ArgumentError) do
      method.create_credential(automatic_challenge(amount: "0", chain_id: nil))
    end
    assert_not_requested(:post, %r{https?://})
  end

  def test_positive_amount_still_builds_transaction
    skip "eth gem not available" unless @eth_available

    method = Mpp::Methods::Tempo::TempoMethod.new(account: account(KEY_A), chain_id: 4217)
    method.stub(:build_tempo_transfer, ["0x1234", 4217]) do
      credential = method.create_credential(automatic_challenge(amount: "1", chain_id: 4217))
      assert_equal({"type" => "transaction", "signature" => "0x1234"}, credential.payload)
    end
  end

  def test_transport_automatically_completes_zero_amount_challenge
    skip "eth gem not available" unless @eth_available

    method = Mpp::Methods::Tempo::TempoMethod.new(account: account(KEY_A))
    challenge = automatic_challenge(amount: "0", chain_id: 4217)
    captured = nil
    stub_request(:get, "https://api.example.com/proof")
      .to_return(status: 402, headers: {"WWW-Authenticate" => challenge.to_www_authenticate(REALM)})
    stub_request(:get, "https://api.example.com/proof")
      .with { |request| request.headers["Authorization"]&.start_with?("Payment ") }
      .to_return do |request|
        captured = Mpp::Credential.from_authorization(request.headers.fetch("Authorization"))
        {status: 200, body: "authenticated"}
      end

    response = Mpp::Client::Transport.new(methods: [method]).get("https://api.example.com/proof")

    assert_equal "200", response.code
    assert_equal "proof", captured.payload["type"]
    intent = Mpp::Methods::Tempo::ChargeIntent.new
    assert_equal "success", intent.verify(captured, challenge.request).status
    assert_requested(:get, "https://api.example.com/proof", times: 2)
    assert_not_requested(:post, %r{https?://})
  end

  private

  def automatic_challenge(amount:, chain_id:)
    Mpp::Challenge.create(
      secret_key: "test-secret", realm: REALM, method: "tempo", intent: "charge",
      request: {"amount" => amount, "currency" => "0x00", "recipient" => "0x01",
                "methodDetails" => chain_id ? {"chainId" => chain_id} : {}},
      expires: Mpp::Expires.minutes(5)
    )
  end
end
