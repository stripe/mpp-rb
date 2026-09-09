# frozen_string_literal: true

require "test_helper"

class TestTempoChargeIntent < Minitest::Test
  CURRENCY = "0x20c0000000000000000000000000000000000000"
  HASH = "0xabc123"
  REALM = "api.example.com"
  RECIPIENT = "0x1234567890abcdef1234567890abcdef12345678"
  SENDER = "0x0000000000000000000000000000000000000001"
  CHAIN_ID = Mpp::Methods::Tempo::Defaults::CHAIN_ID
  SOURCE_ADDR = "0x00000000000000000000000000000000000000aa"
  RELAYER = "0x00000000000000000000000000000000000000bb"

  def setup
    @intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test")
  end

  def test_hash_without_explicit_memo_accepts_challenge_bound_attribution_memo
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: "challenge-123"
    )

    receipt = receipt([transfer_log(memo: memo), transfer_log])

    result = verify_hash(receipt, challenge_id: "challenge-123")

    assert_equal HASH, result.reference
  end

  def test_hash_without_explicit_memo_rejects_plain_transfer
    error = assert_raises(Mpp::VerificationError) do
      verify_hash(receipt([transfer_log]), challenge_id: "challenge-123")
    end

    assert_match(/memo is not bound to this challenge/, error.message)
  end

  def test_hash_without_explicit_memo_rejects_wrong_challenge_nonce
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: "challenge-abc"
    )

    error = assert_raises(Mpp::VerificationError) do
      verify_hash(receipt([transfer_log(memo: memo), transfer_log]), challenge_id: "challenge-xyz")
    end

    assert_match(/memo is not bound to this challenge/, error.message)
  end

  def test_hash_without_explicit_memo_rejects_wrong_realm
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: "other.example.com",
      challenge_id: "challenge-123"
    )

    error = assert_raises(Mpp::VerificationError) do
      verify_hash(receipt([transfer_log(memo: memo), transfer_log]), challenge_id: "challenge-123")
    end

    assert_match(/memo is not bound to this challenge/, error.message)
  end

  def test_hash_with_explicit_memo_accepts_exact_memo
    explicit_memo = "0x#{"ab" * 32}"
    result = verify_hash(
      receipt([transfer_log(memo: explicit_memo)]),
      challenge_id: "challenge-123",
      memo: explicit_memo
    )

    assert_equal HASH, result.reference
  end

  def test_initialize_rejects_nil_store
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Tempo::ChargeIntent.new(store: nil)
    end

    assert_match(/store is required/, error.message)
  end

  def test_default_store_rejects_hash_replay
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: "challenge-123"
    )
    receipt_data = receipt([transfer_log(memo: memo)])

    first = verify_hash(receipt_data, challenge_id: "challenge-123")
    assert_equal HASH, first.reference

    error = assert_raises(Mpp::VerificationError) do
      verify_hash(receipt_data, challenge_id: "challenge-123")
    end
    assert_match(/Transaction hash already used/, error.message)
  end

  def test_default_server_blocks_hash_credential_replay
    server = Mpp.create(
      method: Mpp::Methods::Tempo.tempo(
        chain_id: Mpp::Methods::Tempo::Defaults::TESTNET_CHAIN_ID,
        currency: Mpp::Methods::Tempo::Defaults::PATH_USD,
        recipient: RECIPIENT,
        intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new}
      ),
      realm: REALM,
      secret_key: "test-secret"
    )
    challenge = server.charge(nil, "0.01", description: "Paid endpoint")
    assert_instance_of Mpp::Challenge, challenge

    amount = Integer(challenge.request["amount"])
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: REALM, challenge_id: challenge.id)
    tx_hash = "0x#{"ab" * 32}"
    receipt_data = {
      "status" => "0x1",
      "from" => SENDER,
      "logs" => [{
        "address" => Mpp::Methods::Tempo::Defaults::PATH_USD,
        "topics" => [
          Mpp::Methods::Tempo::TRANSFER_WITH_MEMO_TOPIC,
          topic_address(SENDER),
          topic_address(RECIPIENT),
          memo
        ],
        "data" => "0x#{amount.to_s(16).rjust(64, "0")}"
      }]
    }
    auth = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "hash", "hash" => tx_hash}
    ).to_authorization

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, method, params) {
      assert_equal "eth_getTransactionReceipt", method
      assert_equal [tx_hash], params
      receipt_data
    }) do
      _credential, paid = server.charge(auth, "0.01", description: "Paid endpoint")
      assert_equal tx_hash, paid.reference

      error = assert_raises(Mpp::VerificationError) do
        server.charge(auth, "0.01", description: "Paid endpoint")
      end
      assert_match(/Transaction hash already used/, error.message)
    end
  end

  def test_transaction_credential_replay_rejected_after_success
    raw_tx = "0xabcdef1234567890"
    tx_hash = raw_transaction_hash(raw_tx)
    challenge_id = "challenge-123"
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: challenge_id
    )
    receipt_data = receipt([transfer_log(memo: memo)])
    store = Mpp::MemoryStore.new
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test", store: store)
    credential = transaction_credential(raw_tx, challenge_id: challenge_id)
    calls = []

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, method, params) {
      calls << [method, params]

      case method
      when "eth_sendRawTransaction"
        assert_equal [raw_tx], params
        assert_equal Mpp::Methods::Tempo::TRANSACTION_PENDING, store.get("mpp:charge:#{tx_hash.downcase}")
        tx_hash
      when "eth_getTransactionReceipt"
        assert_equal [tx_hash], params
        receipt_data
      else
        raise "unexpected RPC method: #{method}"
      end
    }) do
      first = intent.verify(credential, request_hash)
      assert_equal tx_hash, first.reference

      error = assert_raises(Mpp::VerificationError) do
        intent.verify(credential, request_hash)
      end
      assert_match(/Transaction hash already used/, error.message)
    end

    methods = calls.map(&:first)
    assert_equal 1, methods.count("eth_sendRawTransaction")
    assert_equal 1, methods.count("eth_getTransactionReceipt")
  end

  def test_default_store_rejects_transaction_replay
    raw_tx = "0xabcdef1234567890"
    tx_hash = raw_transaction_hash(raw_tx)
    challenge_id = "challenge-123"
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: challenge_id
    )
    receipt_data = receipt([transfer_log(memo: memo)])
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test")
    credential = transaction_credential(raw_tx, challenge_id: challenge_id)

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, method, params) {
      case method
      when "eth_sendRawTransaction"
        tx_hash
      when "eth_getTransactionReceipt"
        assert_equal [tx_hash], params
        receipt_data
      else
        raise "unexpected RPC method: #{method}"
      end
    }) do
      first = intent.verify(credential, request_hash)
      assert_equal tx_hash, first.reference

      error = assert_raises(Mpp::VerificationError) do
        intent.verify(credential, request_hash)
      end
      assert_match(/Transaction hash already used/, error.message)
    end
  end

  def test_transaction_credential_duplicate_pending_raises_pending_without_rebroadcast
    raw_tx = "0xabcdef1234567890"
    tx_hash = raw_transaction_hash(raw_tx)
    challenge_id = "challenge-123"
    store = Mpp::MemoryStore.new
    store.put("mpp:charge:#{tx_hash.downcase}", Mpp::Methods::Tempo::TRANSACTION_PENDING)
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test", store: store)
    credential = transaction_credential(raw_tx, challenge_id: challenge_id)
    calls = []

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, method, params) {
      calls << [method, params]

      case method
      when "eth_getTransactionReceipt"
        assert_equal [tx_hash], params
        nil
      else
        raise "unexpected RPC method: #{method}"
      end
    }) do
      intent.stub(:sleep, ->(*_) {}) do
        error = assert_raises(Mpp::TransactionPendingError) do
          intent.verify(credential, request_hash)
        end
        assert_match(/pending/, error.message)
      end
    end

    methods = calls.map(&:first)
    assert_equal 0, methods.count("eth_sendRawTransaction")
    assert_equal Mpp::Methods::Tempo::MAX_RECEIPT_RETRY_ATTEMPTS,
      methods.count("eth_getTransactionReceipt")
    assert_equal Mpp::Methods::Tempo::TRANSACTION_PENDING, store.get("mpp:charge:#{tx_hash.downcase}")
  end

  def test_transaction_credential_recovers_receipt_after_ambiguous_broadcast_error
    raw_tx = "0xabcdef1234567890"
    tx_hash = raw_transaction_hash(raw_tx)
    challenge_id = "challenge-123"
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: challenge_id
    )
    receipt_data = receipt([transfer_log(memo: memo)])
    store = Mpp::MemoryStore.new
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test", store: store)
    credential = transaction_credential(raw_tx, challenge_id: challenge_id)
    calls = []

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, method, params) {
      calls << [method, params]

      case method
      when "eth_sendRawTransaction"
        assert_equal [raw_tx], params
        raise "already known"
      when "eth_getTransactionReceipt"
        assert_equal [tx_hash], params
        receipt_data
      else
        raise "unexpected RPC method: #{method}"
      end
    }) do
      result = intent.verify(credential, request_hash)
      assert_equal tx_hash, result.reference

      error = assert_raises(Mpp::VerificationError) do
        intent.verify(credential, request_hash)
      end
      assert_match(/Transaction hash already used/, error.message)
    end

    methods = calls.map(&:first)
    assert_equal 1, methods.count("eth_sendRawTransaction")
    assert_equal 1, methods.count("eth_getTransactionReceipt")
    assert_equal Mpp::Methods::Tempo::TRANSACTION_VERIFIED, store.get("mpp:charge:#{tx_hash.downcase}")
  end

  def test_transaction_credential_releases_reservation_on_definitive_broadcast_failure
    raw_tx = "0xabcdef1234567890"
    tx_hash = raw_transaction_hash(raw_tx)
    challenge_id = "challenge-123"
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: challenge_id
    )
    receipt_data = receipt([transfer_log(memo: memo)])
    store = Mpp::MemoryStore.new
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test", store: store)
    credential = transaction_credential(raw_tx, challenge_id: challenge_id)
    fail_broadcast = true
    calls = []

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, method, params) {
      calls << [method, params]

      case method
      when "eth_sendRawTransaction"
        assert_equal [raw_tx], params
        if fail_broadcast
          fail_broadcast = false
          raise "insufficient funds"
        end
        tx_hash
      when "eth_getTransactionReceipt"
        assert_equal [tx_hash], params
        receipt_data
      else
        raise "unexpected RPC method: #{method}"
      end
    }) do
      error = assert_raises(Mpp::VerificationError) do
        intent.verify(credential, request_hash)
      end
      assert_match(/Transaction submission failed: insufficient funds/, error.message)
      assert_nil store.get("mpp:charge:#{tx_hash.downcase}")

      receipt = intent.verify(credential, request_hash)
      assert_equal tx_hash, receipt.reference
    end

    methods = calls.map(&:first)
    assert_equal 2, methods.count("eth_sendRawTransaction")
    assert_equal 1, methods.count("eth_getTransactionReceipt")
  end

  def test_transaction_credential_rebases_reservation_when_rpc_hash_differs
    raw_tx = "0xabcdef1234567890"
    local_hash = raw_transaction_hash(raw_tx)
    chain_hash = "0x#{"12" * 32}"
    challenge_id = "challenge-123"
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: REALM,
      challenge_id: challenge_id
    )
    receipt_data = receipt([transfer_log(memo: memo)])
    store = Mpp::MemoryStore.new
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test", store: store)
    credential = transaction_credential(raw_tx, challenge_id: challenge_id)

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, method, params) {
      case method
      when "eth_sendRawTransaction"
        assert_equal [raw_tx], params
        chain_hash
      when "eth_getTransactionReceipt"
        assert_equal [chain_hash], params
        receipt_data
      else
        raise "unexpected RPC method: #{method}"
      end
    }) do
      result = intent.verify(credential, request_hash)
      assert_equal chain_hash, result.reference
    end

    assert_equal Mpp::Methods::Tempo::TRANSACTION_VERIFIED, store.get("mpp:charge:#{local_hash.downcase}")
    assert_equal Mpp::Methods::Tempo::TRANSACTION_VERIFIED, store.get("mpp:charge:#{chain_hash.downcase}")
  end

  def test_rebase_keeps_raw_claim_while_canonical_is_pending
    store = Mpp::MemoryStore.new
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test", store: store)
    raw_hash = "0x#{"ab" * 32}"
    chain_hash = "0x#{"cd" * 32}"
    raw_key = "mpp:charge:#{raw_hash}"
    store.put(raw_key, Mpp::Methods::Tempo::TRANSACTION_PENDING)

    canonical_key, canonical = intent.send(
      :rebase_reservation_to_chain_hash, raw_key, raw_hash, chain_hash
    )

    assert_equal "mpp:charge:#{chain_hash}", canonical_key
    assert_equal chain_hash, canonical
    assert_equal Mpp::Methods::Tempo::TRANSACTION_PENDING, store.get(raw_key)
    assert_equal Mpp::Methods::Tempo::TRANSACTION_PENDING, store.get(canonical_key)
  end

  def test_transaction_credential_rejects_rpc_hash_already_claimed
    raw_tx = "0xabcdef1234567890"
    local_hash = raw_transaction_hash(raw_tx)
    chain_hash = "0x#{"12" * 32}"
    challenge_id = "challenge-123"
    store = Mpp::MemoryStore.new
    store.put("mpp:charge:#{chain_hash}", Mpp::Methods::Tempo::TRANSACTION_VERIFIED)
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test", store: store)
    credential = transaction_credential(raw_tx, challenge_id: challenge_id)

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, method, params) {
      case method
      when "eth_sendRawTransaction"
        chain_hash
      else
        raise "unexpected RPC method: #{method}"
      end
    }) do
      error = assert_raises(Mpp::VerificationError) do
        intent.verify(credential, request_hash)
      end
      assert_match(/Transaction hash already used/, error.message)
    end

    assert_equal Mpp::Methods::Tempo::TRANSACTION_VERIFIED, store.get("mpp:charge:#{local_hash.downcase}")
    assert_equal Mpp::Methods::Tempo::TRANSACTION_VERIFIED, store.get("mpp:charge:#{chain_hash}")
  end

  def test_transaction_credential_releases_reservation_on_simulation_failure
    raw_tx = "0xabcdef1234567890"
    tx_hash = raw_transaction_hash(raw_tx)
    challenge_id = "challenge-123"
    store = Mpp::MemoryStore.new
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test", store: store)
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, fee_payer: Object.new)
    credential = transaction_credential(raw_tx, challenge_id: challenge_id)
    request = request_hash.merge("methodDetails" => {"feePayer" => true, "chainId" => CHAIN_ID})
    calls = []

    cosign = lambda do |submitted_raw_tx, _fee_token, request: nil, challenge: nil|
      assert_equal raw_tx, submitted_raw_tx
      assert request
      assert challenge
      [submitted_raw_tx, {"simulate" => true}]
    end
    simulate = lambda do |_simulate_payload, _rpc_url|
      assert_equal Mpp::Methods::Tempo::TRANSACTION_PENDING, store.get("mpp:charge:#{tx_hash.downcase}")
      raise Mpp::VerificationError, "simulation failed"
    end

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, method, params) {
      calls << [method, params]
      raise "unexpected RPC method: #{method}"
    }) do
      intent.stub(:cosign_as_fee_payer, cosign) do
        intent.stub(:simulate_before_broadcast, simulate) do
          error = assert_raises(Mpp::VerificationError) do
            intent.verify(credential, request)
          end
          assert_match(/simulation failed/, error.message)
        end
      end
    end

    assert_empty calls
    assert_nil store.get("mpp:charge:#{tx_hash.downcase}")
  end

  def test_proof_credential_replay_rejected
    account = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    chain_id = 4217
    challenge_id = "challenge-proof-123"

    signature = Mpp::Methods::Tempo::Proof.sign(
      account: account,
      chain_id: chain_id,
      challenge_id: challenge_id,
      realm: REALM
    )

    credential = Mpp::Credential.new(
      challenge: Mpp::ChallengeEcho.new(
        id: challenge_id,
        realm: REALM,
        method: "tempo",
        intent: "charge",
        request: ""
      ),
      payload: {"type" => "proof", "signature" => signature},
      source: Mpp::Methods::Tempo::Proof.source(address: account.address, chain_id: chain_id)
    )

    request = {
      "amount" => "0",
      "currency" => CURRENCY,
      "recipient" => RECIPIENT,
      "methodDetails" => {"chainId" => chain_id}
    }

    store = Mpp::MemoryStore.new
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test", store: store)

    # First submission succeeds and records the proof under its challenge id.
    receipt = intent.verify(credential, request)
    assert_equal challenge_id, receipt.reference
    assert store.get("mpp:proof:#{challenge_id}")

    # Replaying the identical credential is rejected.
    error = assert_raises(Mpp::VerificationError) do
      intent.verify(credential, request)
    end
    assert_match(/already been used/, error.message)
  end

  def test_default_store_rejects_proof_replay
    account = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    chain_id = 4217
    challenge_id = "challenge-proof-default"

    signature = Mpp::Methods::Tempo::Proof.sign(
      account: account,
      chain_id: chain_id,
      challenge_id: challenge_id,
      realm: REALM
    )

    credential = Mpp::Credential.new(
      challenge: Mpp::ChallengeEcho.new(
        id: challenge_id,
        realm: REALM,
        method: "tempo",
        intent: "charge",
        request: ""
      ),
      payload: {"type" => "proof", "signature" => signature},
      source: Mpp::Methods::Tempo::Proof.source(address: account.address, chain_id: chain_id)
    )

    request = {
      "amount" => "0",
      "currency" => CURRENCY,
      "recipient" => RECIPIENT,
      "methodDetails" => {"chainId" => chain_id}
    }

    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test")

    receipt = intent.verify(credential, request)
    assert_equal challenge_id, receipt.reference

    error = assert_raises(Mpp::VerificationError) do
      intent.verify(credential, request)
    end
    assert_match(/already been used/, error.message)
  end

  def test_parse_hash_credential_source_absent_is_nil
    assert_nil @intent.send(:parse_hash_credential_source, nil, CHAIN_ID)
  end

  def test_parse_hash_credential_source_valid_returns_address
    source = did_pkh(CHAIN_ID, SOURCE_ADDR)
    assert_equal SOURCE_ADDR, @intent.send(:parse_hash_credential_source, source, CHAIN_ID)
  end

  def test_parse_hash_credential_source_chain_mismatch_rejected
    error = assert_raises(Mpp::VerificationError) do
      @intent.send(:parse_hash_credential_source, did_pkh(1, SOURCE_ADDR), CHAIN_ID)
    end
    assert_match(/Hash credential source is invalid/, error.message)
  end

  def test_parse_hash_credential_source_accepts_string_chain_id
    source = did_pkh(CHAIN_ID, SOURCE_ADDR)
    assert_equal SOURCE_ADDR, @intent.send(:parse_hash_credential_source, source, CHAIN_ID.to_s)
  end

  def test_parse_hash_credential_source_rejects_non_numeric_chain_id
    error = assert_raises(Mpp::VerificationError) do
      @intent.send(:parse_hash_credential_source, did_pkh(CHAIN_ID, SOURCE_ADDR), "not-a-number")
    end
    assert_match(/Hash credential source is invalid/, error.message)
  end

  def test_parse_hash_credential_source_rejects_malformed_variants
    [
      "not-a-valid-did",
      "did:pkh:solana:#{CHAIN_ID}:#{SOURCE_ADDR}",
      "did:pkh:eip155:04217:#{SOURCE_ADDR}",
      "did:pkh:eip155:not-a-number:#{SOURCE_ADDR}",
      "did:pkh:eip155:#{CHAIN_ID}:extra:#{SOURCE_ADDR}",
      "did:pkh:eip155:#{CHAIN_ID}:not-an-address"
    ].each do |source|
      error = assert_raises(Mpp::VerificationError, "case: #{source}") do
        @intent.send(:parse_hash_credential_source, source, CHAIN_ID)
      end
      assert_match(/Hash credential source is invalid/, error.message, "case: #{source}")
    end
  end

  def test_hash_accepts_source_matching_transfer_sender
    receipt = receipt([transfer_log(memo: bound_memo, from: SOURCE_ADDR)])
    result = verify_hash_source(receipt, source: did_pkh(CHAIN_ID, SOURCE_ADDR))
    assert_equal HASH, result.reference
  end

  def test_hash_accepts_source_when_receipt_sender_differs
    # Relayer submitted the tx (receipt.from = RELAYER) but the transfer is
    # from the declared source.
    receipt = {"status" => "0x1", "from" => RELAYER,
               "logs" => [transfer_log(memo: bound_memo, from: SOURCE_ADDR)]}
    result = verify_hash_source(receipt, source: did_pkh(CHAIN_ID, SOURCE_ADDR))
    assert_equal HASH, result.reference
  end

  def test_hash_rejects_source_differing_from_transfer_sender
    receipt = receipt([transfer_log(memo: bound_memo, from: RELAYER)])
    error = assert_raises(Mpp::VerificationError) do
      verify_hash_source(receipt, source: did_pkh(CHAIN_ID, SOURCE_ADDR))
    end
    assert_match(/must contain a Transfer log/, error.message)
  end

  def test_hash_validate_sender_override_allows_mismatch
    seen = {}
    intent = Mpp::Methods::Tempo::ChargeIntent.new(
      rpc_url: "https://rpc.example.test",
      validate_sender: ->(expected_sender:, sender:, source:) {
        seen = {expected_sender: expected_sender, sender: sender, source: source}
        true
      }
    )
    receipt = receipt([transfer_log(memo: bound_memo, from: RELAYER)])
    result = verify_hash_source(receipt, source: did_pkh(CHAIN_ID, SOURCE_ADDR), intent: intent)

    assert_equal HASH, result.reference
    assert_equal SOURCE_ADDR.downcase, seen[:expected_sender].downcase
    assert_equal RELAYER.downcase, seen[:sender].downcase
    assert_equal did_pkh(CHAIN_ID, SOURCE_ADDR), seen[:source]
  end

  def test_hash_validate_sender_returning_false_rejects
    intent = Mpp::Methods::Tempo::ChargeIntent.new(
      rpc_url: "https://rpc.example.test",
      validate_sender: ->(expected_sender:, sender:, source:) { false }
    )
    receipt = receipt([transfer_log(memo: bound_memo, from: RELAYER)])
    error = assert_raises(Mpp::VerificationError) do
      verify_hash_source(receipt, source: did_pkh(CHAIN_ID, SOURCE_ADDR), intent: intent)
    end
    assert_match(/must contain a Transfer log/, error.message)
  end

  def test_hash_no_source_ignores_validate_sender_override
    # With no declared source the override must not apply: a transfer whose
    # sender differs from receipt["from"] must still be rejected even if the
    # callback would authorize it.
    intent = Mpp::Methods::Tempo::ChargeIntent.new(
      rpc_url: "https://rpc.example.test",
      validate_sender: ->(expected_sender:, sender:, source:) { true }
    )
    # receipt["from"] is SENDER, but the transfer log is from RELAYER.
    receipt = receipt([transfer_log(memo: bound_memo, from: RELAYER)])
    error = assert_raises(Mpp::VerificationError) do
      verify_hash_source(receipt, source: nil, intent: intent)
    end
    assert_match(/must contain a Transfer log/, error.message)
  end

  def test_hash_rejects_source_from_different_chain
    receipt = receipt([transfer_log(memo: bound_memo, from: SOURCE_ADDR)])
    error = assert_raises(Mpp::VerificationError) do
      verify_hash_source(receipt, source: did_pkh(1, SOURCE_ADDR))
    end
    assert_match(/Hash credential source is invalid/, error.message)
  end

  def test_hash_validate_sender_not_called_when_sender_matches
    intent = Mpp::Methods::Tempo::ChargeIntent.new(
      rpc_url: "https://rpc.example.test",
      validate_sender: ->(expected_sender:, sender:, source:) { raise "must not be called" }
    )
    receipt = receipt([transfer_log(memo: bound_memo, from: SOURCE_ADDR)])
    result = verify_hash_source(receipt, source: did_pkh(CHAIN_ID, SOURCE_ADDR), intent: intent)
    assert_equal HASH, result.reference
  end

  def test_hash_validate_sender_not_called_for_non_candidate_logs
    explicit_memo = "0x#{"ab" * 32}"
    other_memo = "0x#{"cd" * 32}"
    intent = Mpp::Methods::Tempo::ChargeIntent.new(
      rpc_url: "https://rpc.example.test",
      validate_sender: ->(expected_sender:, sender:, source:) { raise "must not be called" }
    )
    # First log has a wrong sender and a non-matching memo (non-candidate);
    # second log matches fully, so the callback is never reached.
    receipt = receipt([
      transfer_log(memo: other_memo, from: RELAYER),
      transfer_log(memo: explicit_memo, from: SOURCE_ADDR)
    ])
    credential = Mpp::Credential.new(
      challenge: Mpp::ChallengeEcho.new(id: "challenge-123", realm: REALM, method: "tempo",
        intent: "charge", request: ""),
      payload: {"type" => "hash", "hash" => HASH},
      source: did_pkh(CHAIN_ID, SOURCE_ADDR)
    )
    result = Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, _method, _params) { receipt }) do
      intent.verify(credential, request_hash(memo: explicit_memo))
    end
    assert_equal HASH, result.reference
  end

  def test_hash_malformed_source_does_not_consume_hash
    store = Mpp::MemoryStore.new
    intent = Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: "https://rpc.example.test", store: store)
    receipt = receipt([transfer_log(memo: bound_memo, from: SOURCE_ADDR)])

    # Malformed source is rejected before the hash is reserved.
    assert_raises(Mpp::VerificationError) do
      verify_hash_source(receipt, source: "not-a-valid-did", intent: intent)
    end
    assert_nil store.get("mpp:charge:#{HASH.downcase}")

    # A valid retry then succeeds.
    result = verify_hash_source(receipt, source: did_pkh(CHAIN_ID, SOURCE_ADDR), intent: intent)
    assert_equal HASH, result.reference
  end

  private

  def did_pkh(chain_id, address)
    "did:pkh:eip155:#{chain_id}:#{address}"
  end

  def bound_memo
    Mpp::Methods::Tempo::Attribution.encode(server_id: REALM, challenge_id: "challenge-123")
  end

  def verify_hash_source(receipt, source:, intent: @intent, challenge_id: "challenge-123")
    credential = Mpp::Credential.new(
      challenge: Mpp::ChallengeEcho.new(
        id: challenge_id,
        realm: REALM,
        method: "tempo",
        intent: "charge",
        request: ""
      ),
      payload: {"type" => "hash", "hash" => HASH},
      source: source
    )

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, _method, _params) { receipt }) do
      intent.verify(credential, request_hash)
    end
  end

  def raw_transaction_hash(raw_tx)
    "0x#{Mpp::Methods::Tempo::Attribution.keccak256([raw_tx.delete_prefix("0x")].pack("H*")).unpack1("H*")}"
  end

  def transaction_credential(raw_tx, challenge_id:)
    Mpp::Credential.new(
      challenge: Mpp::ChallengeEcho.new(
        id: challenge_id,
        realm: REALM,
        method: "tempo",
        intent: "charge",
        request: ""
      ),
      payload: {"type" => "transaction", "signature" => raw_tx}
    )
  end

  def verify_hash(receipt, challenge_id:, memo: nil)
    credential = Mpp::Credential.new(
      challenge: Mpp::ChallengeEcho.new(
        id: challenge_id,
        realm: REALM,
        method: "tempo",
        intent: "charge",
        request: ""
      ),
      payload: {"type" => "hash", "hash" => HASH}
    )

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(_rpc_url, method, params) {
      assert_equal "eth_getTransactionReceipt", method
      assert_equal [HASH], params
      receipt
    }) do
      @intent.verify(credential, request_hash(memo: memo))
    end
  end

  def request_hash(memo: nil)
    request = {
      "amount" => "1000",
      "currency" => CURRENCY,
      "recipient" => RECIPIENT
    }
    request["methodDetails"] = {"memo" => memo} if memo
    request
  end

  def receipt(logs)
    {"status" => "0x1", "from" => SENDER, "logs" => logs}
  end

  def transfer_log(memo: nil, from: SENDER)
    topics = [
      memo ? Mpp::Methods::Tempo::TRANSFER_WITH_MEMO_TOPIC : Mpp::Methods::Tempo::TRANSFER_TOPIC,
      topic_address(from),
      topic_address(RECIPIENT)
    ]
    topics << memo if memo

    {
      "address" => CURRENCY,
      "topics" => topics,
      "data" => "0x#{1000.to_s(16).rjust(64, "0")}"
    }
  end

  def topic_address(address)
    "0x#{address.delete_prefix("0x").rjust(64, "0")}"
  end
end
