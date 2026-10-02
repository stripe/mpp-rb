# frozen_string_literal: true

require "test_helper"

# Server Tempo methods offer one charge per accepted currency: OUSD first,
# then USDC.e on mainnet or pathUSD on Moderato.
class TestTempoCurrencyOffers < Minitest::Test
  D = Mpp::Methods::Tempo::Defaults

  OUSD = "0x20c0000000000000000000006a37DA5C996874BE"
  USDC = "0x20C000000000000000000000b9537d11c60E8b50"
  PATH_USD = "0x20c0000000000000000000000000000000000000"
  REALM = "api.example.com"
  SECRET = "test-currency-offers-secret"
  RECIPIENT = "0x1234567890abcdef1234567890abcdef12345678"
  SENDER = "0x0000000000000000000000000000000000000001"
  TX_HASH = "0x#{"ab" * 32}"

  StubIntent = Struct.new(:name, :verified) do
    def verify(_credential, request)
      verified << request
      Mpp::Receipt.success("0xstub", method: "tempo")
    end
  end

  StubMethod = Struct.new(:name, :intents, :currency, :recipient, :decimals)

  # Defaults

  def test_minimal_factory_offers_mainnet_currencies
    method = tempo
    assert_equal 4217, method.chain_id
    assert_equal D::RPC_URL, method.rpc_url
    offers = handler_for(method).charge(nil, "1.00").challenges
    assert_equal [OUSD, USDC], offers.map { |offer| offer.request["currency"] }
  end

  def test_fee_token_configuration_requires_local_payer
    [nil, "https://sponsor.example.test"].each do |payer|
      assert_raises(ArgumentError) { tempo(fee_payer: payer, fee_token: USDC) }
    end
    assert_raises(ArgumentError) { tempo(fee_payer_allowed_fee_tokens: []) }
    assert_raises(ArgumentError) { tempo(fee_payer: fee_payer_account, fee_token: "invalid") }
  end

  def test_ousd_address
    assert_equal OUSD, D::OUSD
  end

  def test_default_currencies_mainnet_are_ousd_then_usdc
    assert_equal [OUSD, USDC], D.default_currencies_for_chain(4217)
  end

  def test_default_currencies_moderato_are_ousd_then_path_usd
    assert_equal [OUSD, PATH_USD], D.default_currencies_for_chain(42_431)
  end

  def test_default_currencies_unknown_chain_keep_single_legacy_default
    assert_equal [PATH_USD], D.default_currencies_for_chain(99_999)
  end

  def test_default_currencies_nil_chain_keep_single_legacy_default
    assert_equal [PATH_USD], D.default_currencies_for_chain(nil)
  end

  def test_default_currencies_are_frozen
    assert_predicate D.default_currencies_for_chain(4217), :frozen?
    assert_predicate D.default_currencies_for_chain(42_431), :frozen?
  end

  def test_default_currency_for_chain_is_unchanged
    assert_equal USDC, D.default_currency_for_chain(4217)
    assert_equal PATH_USD, D.default_currency_for_chain(42_431)
    assert_equal PATH_USD, D.default_currency_for_chain(99_999)
    assert_equal PATH_USD, D.default_currency_for_chain(nil)
  end

  def test_resolve_currency_is_unchanged
    assert_equal USDC, D.resolve_currency
    assert_equal PATH_USD, D.resolve_currency(testnet: true)
    assert_equal USDC, D.resolve_currency(chain_id: 4217, testnet: true)
    assert_equal PATH_USD, D.resolve_currency(chain_id: 42_431)
  end

  def test_accepted_currencies_defaults_follow_chain
    assert_equal [OUSD, USDC], D.accepted_currencies(chain_id: 4217)
    assert_equal [OUSD, PATH_USD], D.accepted_currencies(chain_id: 42_431)
    assert_equal [PATH_USD], D.accepted_currencies(chain_id: 31_337)
    assert_equal [PATH_USD], D.accepted_currencies
  end

  def test_accepted_currencies_explicit_list_replaces_defaults_in_order
    assert_equal [USDC, OUSD], D.accepted_currencies(chain_id: 4217, currencies: [USDC, OUSD])
    assert_equal [PATH_USD, USDC], D.accepted_currencies(chain_id: 4217, currencies: [PATH_USD, USDC])
  end

  def test_accepted_currencies_single_element_list
    assert_equal [OUSD], D.accepted_currencies(chain_id: 4217, currencies: [OUSD])
  end

  def test_accepted_currencies_legacy_currency_restricts_to_one
    assert_equal [USDC], D.accepted_currencies(chain_id: 4217, currency: USDC)
    assert_equal [PATH_USD], D.accepted_currencies(chain_id: 42_431, currency: PATH_USD)
  end

  def test_accepted_currencies_rejects_both_options
    error = assert_raises(ArgumentError) do
      D.accepted_currencies(currency: USDC, currencies: [OUSD])
    end
    assert_equal "pass currency: or currencies:, not both", error.message
  end

  def test_accepted_currencies_rejects_empty_list
    error = assert_raises(ArgumentError) { D.accepted_currencies(chain_id: 4217, currencies: []) }
    assert_equal "currencies must not be empty", error.message
  end

  def test_accepted_currencies_dedupes_case_insensitively_preserving_order
    currencies = [USDC, OUSD, OUSD.downcase, USDC.downcase, OUSD.upcase.sub("0X", "0x")]

    assert_equal [USDC, OUSD], D.accepted_currencies(currencies: currencies)
  end

  def test_accepted_currencies_rejects_invalid_addresses
    ["usd", "0x1234", "20c0000000000000000000006a37DA5C996874BE", "0x#{"g" * 40}", "0x#{"a" * 41}", "#{OUSD}\n", nil].each do |invalid|
      error = assert_raises(ArgumentError, "expected #{invalid.inspect} to be rejected") do
        D.accepted_currencies(currencies: [OUSD, invalid])
      end
      assert_equal "Invalid Tempo currency address: #{invalid.inspect}", error.message
    end
  end

  # Factory

  def test_factory_mainnet_defaults
    method = tempo(chain_id: 4217)

    assert_equal [OUSD, USDC], method.currencies
    assert_equal USDC, method.currency
  end

  def test_factory_moderato_defaults
    method = tempo(chain_id: 42_431)

    assert_equal [OUSD, PATH_USD], method.currencies
    assert_equal PATH_USD, method.currency
  end

  def test_factory_explicit_chain_id_selects_defaults_regardless_of_rpc_url
    method = tempo(chain_id: 42_431, rpc_url: D::RPC_URL)

    assert_equal [OUSD, PATH_USD], method.currencies
  end

  def test_factory_explicit_nil_chain_keeps_legacy_single_default
    method = tempo(chain_id: nil)

    assert_equal [PATH_USD], method.currencies
    assert_equal PATH_USD, method.currency
  end

  def test_factory_custom_chain_keeps_legacy_single_default
    method = tempo(chain_id: 31_337, rpc_url: "http://localhost:8545")

    assert_equal [PATH_USD], method.currencies
    assert_equal PATH_USD, method.currency
  end

  def test_factory_explicit_currencies_replace_defaults
    method = tempo(chain_id: 4217, currencies: [USDC, OUSD])

    assert_equal [USDC, OUSD], method.currencies
    assert_equal USDC, method.currency
  end

  def test_factory_legacy_currency_restricts_to_one
    method = tempo(chain_id: 4217, currency: USDC)

    assert_equal [USDC], method.currencies
    assert_equal USDC, method.currency
  end

  def test_factory_rejects_invalid_currency_options
    assert_raises(ArgumentError) { tempo(currency: USDC, currencies: [OUSD]) }
    assert_raises(ArgumentError) { tempo(chain_id: 4217, currencies: []) }
    assert_raises(ArgumentError) { tempo(chain_id: 4217, currencies: ["0x1234"]) }
  end

  def test_factory_currencies_are_frozen_copy
    input = [USDC, OUSD]
    method = tempo(currencies: input)
    input << PATH_USD

    assert_equal [USDC, OUSD], method.currencies
    assert_predicate method.currencies, :frozen?
  end

  def test_client_default_currency_is_unchanged_per_chain
    account = Mpp::Methods::Tempo::Account.from_key("0x#{"11" * 32}")
    {4217 => USDC, 42_431 => PATH_USD, 31_337 => PATH_USD, nil => PATH_USD}.each do |chain_id, expected|
      kwargs = {account: account, intents: {"charge" => StubIntent.new("charge", [])}}
      kwargs[:chain_id] = chain_id
      kwargs[:rpc_url] = "http://localhost:8545" if chain_id == 31_337

      assert_equal expected, Mpp::Methods::Tempo.tempo(**kwargs).currency, "chain #{chain_id.inspect}"
    end
  end

  def test_explicit_currencies_set_primary_currency
    assert_equal OUSD, tempo(chain_id: 4217, currencies: [OUSD, USDC]).currency
    assert_equal OUSD, tempo(chain_id: 4217, currencies: [OUSD, OUSD.downcase]).currency
  end

  def test_direct_constructor_derives_currencies_from_currency
    assert_equal [USDC], Mpp::Methods::Tempo::TempoMethod.new(currency: USDC).currencies
    assert_equal [], Mpp::Methods::Tempo::TempoMethod.new.currencies
  end

  # Challenges

  def test_mainnet_charge_offers_ousd_then_usdc
    result = handler_for(tempo(chain_id: 4217)).charge(nil, "1.00")

    assert_instance_of Mpp::Server::ComposedResult, result
    assert result.payment_required?
    assert_equal [OUSD, USDC], result.challenges.map { |challenge| challenge.request["currency"] }
    result.challenges.each do |challenge|
      assert_equal "tempo", challenge.method
      assert_equal "charge", challenge.intent
      assert_equal "1000000", challenge.request["amount"]
      assert_equal RECIPIENT, challenge.request["recipient"]
      assert_equal({"chainId" => 4217}, challenge.request["methodDetails"])
    end
    assert_equal 2, result.challenges.map(&:id).uniq.length
  end

  def test_moderato_charge_offers_ousd_then_path_usd
    result = handler_for(tempo(chain_id: 42_431)).charge(nil, "1.00")

    assert_equal [OUSD, PATH_USD], result.challenges.map { |challenge| challenge.request["currency"] }
    assert(result.challenges.all? { |challenge| challenge.request["methodDetails"] == {"chainId" => 42_431} })
  end

  def test_charge_response_has_one_www_authenticate_per_currency
    response = handler_for(tempo(chain_id: 4217)).charge(nil, "1.00").to_response
    values = response["headers"]["WWW-Authenticate"]

    assert_equal 402, response["status"]
    assert_equal 2, values.length
    currencies = values.map { |value| Mpp::Challenge.from_www_authenticate(value).request["currency"] }
    assert_equal [OUSD, USDC], currencies
  end

  def test_explicit_currencies_control_offer_order
    result = handler_for(tempo(chain_id: 4217, currencies: [USDC, PATH_USD, OUSD])).charge(nil, "1.00")

    assert_equal [USDC, PATH_USD, OUSD], result.challenges.map { |challenge| challenge.request["currency"] }
  end

  def test_single_element_currencies_returns_single_challenge
    result = handler_for(tempo(chain_id: 4217, currencies: [OUSD])).charge(nil, "1.00")

    assert_instance_of Mpp::Challenge, result
    assert_equal OUSD, result.request["currency"]
  end

  def test_legacy_currency_returns_single_challenge
    result = handler_for(tempo(chain_id: 4217, currency: USDC)).charge(nil, "1.00")

    assert_instance_of Mpp::Challenge, result
    assert_equal USDC, result.request["currency"]
  end

  def test_unknown_chain_returns_single_legacy_challenge
    result = handler_for(tempo(chain_id: nil)).charge(nil, "1.00")

    assert_instance_of Mpp::Challenge, result
    assert_equal PATH_USD, result.request["currency"]
  end

  def test_per_request_currency_override_returns_single_challenge
    handler = handler_for(tempo(chain_id: 4217))

    usdc = handler.charge(nil, "1.00", currency: USDC)
    other = handler.charge(nil, "1.00", currency: PATH_USD)

    assert_instance_of Mpp::Challenge, usdc
    assert_equal USDC, usdc.request["currency"]
    assert_instance_of Mpp::Challenge, other
    assert_equal PATH_USD, other.request["currency"]
  end

  def test_compose_expands_currencies_before_other_methods
    method = tempo(chain_id: 4217)
    stripe = StubMethod.new("stripe", {"charge" => StubIntent.new("charge", [])}, "usd", "acct_123", 2)
    handler = Mpp::Server::MppHandler.new(methods: [method, stripe], realm: REALM, secret_key: SECRET)

    implicit = handler.charge(nil, "1.00")
    explicit = handler.compose([method, {amount: "1.00"}], [stripe, {amount: "1.00"}]).call

    [implicit, explicit].each do |result|
      assert_equal ["tempo", "tempo", "stripe"], result.challenges.map(&:method)
      assert_equal [OUSD, USDC, "usd"], result.challenges.map { |challenge| challenge.request["currency"] }
    end
  end

  def test_compose_entry_currency_pins_single_offer
    method = tempo(chain_id: 4217)
    result = handler_for(method).compose([method, {"amount" => "1.00", "currency" => USDC}]).call

    assert_equal [USDC], result.challenges.map { |challenge| challenge.request["currency"] }
  end

  def test_can_offer_filters_individual_currencies
    method = tempo(chain_id: 4217, can_offer: ->(request) { request["currency"] != OUSD })
    result = handler_for(method).charge(nil, "1.00")

    assert_equal [USDC], result.challenges.map { |challenge| challenge.request["currency"] }
  end

  # Credentials (real ChargeIntent, stubbed RPC receipt)

  def test_usdc_credential_verifies_against_ousd_first_offers
    assert_paid_with(USDC)
  end

  def test_ousd_credential_verifies
    assert_paid_with(OUSD)
  end

  def test_moderato_path_usd_credential_verifies
    assert_paid_with(PATH_USD, chain_id: 42_431)
  end

  def test_usdc_offer_rejects_transfer_in_ousd
    method = tempo(chain_id: 4217, intent: Mpp::Methods::Tempo::ChargeIntent.new)
    handler = handler_for(method)
    challenge = handler.charge(nil, "1.00").challenges.find { |item| item.request["currency"] == USDC }

    error = assert_raises(Mpp::VerificationError) do
      with_receipt(challenge, token: OUSD) do
        handler.charge(hash_credential(challenge).to_authorization, "1.00")
      end
    end

    assert_equal "Transaction must contain a Transfer log matching request parameters", error.message
  end

  def test_non_offered_currency_is_rejected
    intent = StubIntent.new("charge", [])
    handler = handler_for(tempo(chain_id: 4217, intent: intent))
    offered = handler.charge(nil, "1.00").challenges.first
    forged = Mpp::Challenge.create(
      secret_key: SECRET,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: offered.request.merge("currency" => PATH_USD),
      expires: offered.expires
    )

    result = handler.charge(hash_credential(forged).to_authorization, "1.00")

    assert result.payment_required?
    assert_empty intent.verified
    refute_includes result.challenges.map { |challenge| challenge.request["currency"] }, PATH_USD
  end

  def test_credential_for_each_offer_reaches_intent_with_its_currency
    intent = StubIntent.new("charge", [])
    handler = handler_for(tempo(chain_id: 4217, intent: intent))

    handler.charge(nil, "1.00").challenges.each do |challenge|
      result = handler.charge(hash_credential(challenge).to_authorization, "1.00")
      refute result.payment_required?
    end

    assert_equal [OUSD, USDC], intent.verified.map { |request| request["currency"] }
  end

  def test_per_request_override_verifies_its_credential
    intent = StubIntent.new("charge", [])
    handler = handler_for(tempo(chain_id: 4217, intent: intent))
    challenge = handler.charge(nil, "1.00", currency: PATH_USD)

    result = handler.charge(hash_credential(challenge).to_authorization, "1.00", currency: PATH_USD)

    credential, receipt = result
    assert_instance_of Mpp::Credential, credential
    assert_equal "success", receipt.status
    assert_equal [PATH_USD], intent.verified.map { |request| request["currency"] }
  end

  # Sponsored charges: fee token is independent of the charge currency

  def test_default_fee_tokens
    assert_equal [PATH_USD, USDC], D.default_fee_tokens(4217)
    assert_equal [PATH_USD], D.default_fee_tokens(42_431)
    assert_equal [PATH_USD], D.default_fee_tokens(99_999)
    assert_equal [PATH_USD], D.default_fee_tokens(nil)
  end

  def test_sponsored_defaults_emit_both_offers
    [[4217, [OUSD, USDC]], [42_431, [OUSD, PATH_USD]]].each do |chain_id, expected|
      [fee_payer_account, "https://sponsor.example.test"].each do |fee_payer|
        method = tempo(chain_id: chain_id, fee_payer: fee_payer)
        result = handler_for(method).charge(nil, "1.00")

        assert_equal expected, method.currencies
        assert_equal expected, result.challenges.map { |challenge| challenge.request["currency"] }
        assert(result.challenges.all? { |challenge| challenge.request["methodDetails"] == {"chainId" => chain_id, "feePayer" => true} })
      end
    end
  end

  def test_fee_token_requires_local_fee_payer
    error = assert_raises(ArgumentError) do
      tempo(chain_id: 4217, fee_payer: "https://sponsor.example.test", fee_token: USDC)
    end
    assert_equal "fee_token can only be configured for a local fee payer", error.message
  end

  def test_sponsored_ousd_charge_on_mainnet_pays_fees_in_funded_token
    assert_sponsored_charge(chain_id: 4217, currency: OUSD, funded: [USDC], expected_fee_token: USDC)
  end

  def test_sponsored_ousd_charge_on_moderato_pays_fees_in_path_usd
    assert_sponsored_charge(chain_id: 42_431, currency: OUSD, funded: [PATH_USD], expected_fee_token: PATH_USD)
  end

  def test_sponsored_usdc_charge_on_mainnet_prefers_funded_path_usd
    assert_sponsored_charge(chain_id: 4217, currency: USDC, funded: [PATH_USD, USDC], expected_fee_token: PATH_USD)
  end

  def test_fee_token_selection_first_funded_wins
    assert_equal [PATH_USD, [PATH_USD]], select_fee_token(funded: [PATH_USD, USDC])
    assert_equal [USDC, [PATH_USD, USDC]], select_fee_token(funded: [USDC])
  end

  def test_fee_token_selection_falls_back_to_first_allowed_when_none_funded
    assert_equal [PATH_USD, [PATH_USD, USDC]], select_fee_token(funded: [])
  end

  def test_fee_token_selection_treats_rpc_errors_as_unfunded
    assert_equal [USDC, [PATH_USD, USDC]], select_fee_token(funded: [USDC], failing: [PATH_USD])
  end

  def test_configured_fee_token_wins_without_balance_lookups
    assert_equal [USDC, []], select_fee_token(funded: [PATH_USD], fee_token: USDC)
  end

  def test_explicit_allowlist_is_respected
    assert_equal [USDC, [USDC]], select_fee_token(funded: [PATH_USD, USDC], allowed: [USDC])
    assert_equal [USDC, [USDC]], select_fee_token(funded: [], allowed: [USDC])
    assert_equal [OUSD, [OUSD]], select_fee_token(funded: [OUSD], allowed: [OUSD])
  end

  def test_disallowed_fee_tokens_are_rejected
    [OUSD, "0x20c0000000000000000000000000000000000001"].each do |token|
      error = assert_raises(Mpp::VerificationError) { select_fee_token(funded: [], explicit: token) }
      assert_equal "Fee token #{token} is not allowed by fee payer policy", error.message
    end
    error = assert_raises(Mpp::VerificationError) { select_fee_token(funded: [], fee_token: OUSD) }
    assert_equal "Fee token #{OUSD} is not allowed by fee payer policy", error.message
    error = assert_raises(Mpp::VerificationError) { select_fee_token(funded: [], explicit: PATH_USD, allowed: [USDC]) }
    assert_equal "Fee token #{PATH_USD} is not allowed by fee payer policy", error.message
  end

  def test_sponsored_validation_makes_no_rpc_calls_and_checks_configured_fee_token
    require "eth"
    require "rlp"

    intent = Mpp::Methods::Tempo::ChargeIntent.new
    handler = handler_for(tempo(chain_id: 4217, fee_payer: fee_payer_account, intent: intent))
    challenge = handler.charge(nil, "1.00").challenges.first
    credential = sponsored_credential(challenge, currency: OUSD)
    request = challenge.request

    Mpp::Methods::Tempo::Rpc.stub(:call, ->(*_) { flunk "validation must not call RPC" }) do
      assert intent.validate(credential, request)
    end

    tempo(chain_id: 4217, fee_payer: fee_payer_account, intent: intent, fee_token: OUSD)
    error = assert_raises(Mpp::VerificationError) { intent.validate(credential, request) }
    assert_equal "Fee token #{OUSD} is not allowed by fee payer policy", error.message
  end

  private

  def fee_payer_account
    @fee_payer_account ||= Mpp::Methods::Tempo::Account.from_key("0x#{"22" * 32}")
  end

  def payer_account
    @payer_account ||= Mpp::Methods::Tempo::Account.from_key("0x#{"33" * 32}")
  end

  def sponsored_credential(challenge, currency:)
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: REALM, challenge_id: challenge.id)
    data = "0x#{Mpp::Methods::Tempo::TRANSFER_WITH_MEMO_SELECTOR}#{RECIPIENT.delete_prefix("0x").rjust(64, "0")}" \
      "#{1_000_000.to_s(16).rjust(64, "0")}#{memo.delete_prefix("0x")}"
    chain_id = challenge.request["methodDetails"]["chainId"]
    raw_tx, = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: payer_account, chain_id: chain_id, gas_limit: 100_000, gas_price: 1,
      nonce: 0, nonce_key: (1 << 256) - 1, currency: currency, transfer_data: data,
      valid_before: Time.now.to_i + 20, awaiting_fee_payer: true
    )
    Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "transaction", "signature" => raw_tx},
      source: "did:pkh:eip155:#{chain_id}:#{payer_account.address}"
    )
  end

  # Returns the fee token encoded in a signed 0x76 transaction.
  def fee_token_of(raw_tx)
    "0x#{RLP.decode([raw_tx.delete_prefix("0x76")].pack("H*"))[10].unpack1("H*")}"
  end

  def balance_of_token(params)
    call, = params
    owner = call["data"].delete_prefix("0x70a08231")
    assert_equal fee_payer_account.address.delete_prefix("0x").downcase.rjust(64, "0"), owner
    canonical(call["to"])
  end

  def canonical(token)
    [PATH_USD, USDC, OUSD].find { |known| known.casecmp?(token) } || token
  end

  def balance_result(token, funded)
    (funded.any? { |item| item.casecmp?(token) }) ? "0x#{1_000_000.to_s(16)}" : "0x0"
  end

  def assert_sponsored_charge(chain_id:, currency:, funded:, expected_fee_token:)
    require "eth"
    require "rlp"

    intent = Mpp::Methods::Tempo::ChargeIntent.new
    handler = handler_for(tempo(chain_id: chain_id, fee_payer: fee_payer_account, intent: intent))
    challenge = handler.charge(nil, "1.00").challenges.find { |item| item.request["currency"] == currency }
    assert challenge, "expected an offer for #{currency}"
    credential = sponsored_credential(challenge, currency: currency)
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: REALM, challenge_id: challenge.id)
    log = {
      "address" => currency,
      "topics" => [Mpp::Methods::Tempo::TRANSFER_WITH_MEMO_TOPIC, topic_address(payer_account.address), topic_address(RECIPIENT), memo],
      "data" => "0x#{1_000_000.to_s(16).rjust(64, "0")}"
    }
    calls = []
    broadcast = nil
    simulated = nil
    rpc = lambda do |_url, rpc_method, params|
      calls << rpc_method
      case rpc_method
      when "eth_call" then balance_result(balance_of_token(params), funded)
      when "tempo_simulateV1"
        simulated = params.first
        {"blocks" => [{"calls" => [{"status" => "0x1"}]}]}
      when "eth_sendRawTransaction"
        broadcast = params.first
        TX_HASH
      when "eth_getTransactionReceipt"
        {"status" => "0x1", "from" => payer_account.address, "logs" => [log]}
      else flunk "unexpected RPC #{rpc_method}"
      end
    end

    result = Mpp::Methods::Tempo::Rpc.stub(:call, rpc) do
      handler.charge(credential.to_authorization, "1.00")
    end

    refute result.payment_required?
    _credential, receipt = result.payment
    assert_equal "success", receipt.status
    assert_equal TX_HASH, receipt.reference
    assert_equal expected_fee_token.downcase, fee_token_of(broadcast)
    assert_includes simulated.to_s.downcase, expected_fee_token.downcase
    assert_equal %w[tempo_simulateV1 eth_sendRawTransaction eth_getTransactionReceipt], calls.reject { |name| name == "eth_call" }
  end

  # Cosigns a sponsored mainnet envelope and returns [fee token, tokens whose
  # balance was queried]. `explicit` passes a fee token directly to cosign.
  def select_fee_token(funded:, failing: [], fee_token: nil, allowed: nil, explicit: nil)
    require "eth"
    require "rlp"

    intent = Mpp::Methods::Tempo::ChargeIntent.new
    tempo(
      chain_id: 4217, fee_payer: fee_payer_account, intent: intent,
      fee_token: fee_token, fee_payer_allowed_fee_tokens: allowed
    )
    raw_tx, = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: payer_account, chain_id: 4217, gas_limit: 100_000, gas_price: 1,
      nonce: 0, nonce_key: (1 << 256) - 1, currency: OUSD,
      transfer_data: "0xa9059cbb#{RECIPIENT.delete_prefix("0x").rjust(64, "0")}#{1_000_000.to_s(16).rjust(64, "0")}",
      valid_before: Time.now.to_i + 20, awaiting_fee_payer: true
    )
    queried = []
    rpc = lambda do |_url, rpc_method, params|
      assert_equal "eth_call", rpc_method
      token = balance_of_token(params)
      queried << token
      raise "rpc unavailable" if failing.include?(token)

      balance_result(token, funded)
    end

    signed, = Mpp::Methods::Tempo::Rpc.stub(:call, rpc) do
      intent.send(:cosign_as_fee_payer, raw_tx, explicit)
    end
    selected = fee_token_of(signed)
    [canonical(selected), queried]
  end

  def tempo(intent: StubIntent.new("charge", []), **kwargs)
    Mpp::Methods::Tempo.tempo(intents: {"charge" => intent}, recipient: RECIPIENT, **kwargs)
  end

  def handler_for(method)
    Mpp::Server::MppHandler.new(method: method, realm: REALM, secret_key: SECRET)
  end

  def hash_credential(challenge)
    Mpp::Credential.new(challenge: challenge.to_echo, payload: {"type" => "hash", "hash" => TX_HASH})
  end

  def assert_paid_with(currency, chain_id: 4217)
    method = tempo(chain_id: chain_id, intent: Mpp::Methods::Tempo::ChargeIntent.new)
    handler = handler_for(method)
    offers = handler.charge(nil, "1.00").challenges
    challenge = offers.find { |item| item.request["currency"] == currency }
    assert challenge, "expected an offer for #{currency}"

    result = with_receipt(challenge, token: currency) do
      handler.charge(hash_credential(challenge).to_authorization, "1.00")
    end

    refute result.payment_required?
    credential, receipt = result.payment
    assert_equal currency, credential.challenge.request.then { |raw| Mpp::Parsing.b64_decode(raw)["currency"] }
    assert_equal "success", receipt.status
    assert_equal TX_HASH, receipt.reference
  end

  def with_receipt(challenge, token:, &block)
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: REALM, challenge_id: challenge.id)
    log = {
      "address" => token,
      "topics" => [
        Mpp::Methods::Tempo::TRANSFER_WITH_MEMO_TOPIC,
        topic_address(SENDER),
        topic_address(RECIPIENT),
        memo
      ],
      "data" => "0x#{1_000_000.to_s(16).rjust(64, "0")}"
    }
    receipt = {"status" => "0x1", "from" => SENDER, "logs" => [log]}
    rpc = lambda do |_url, rpc_method, params|
      assert_equal "eth_getTransactionReceipt", rpc_method
      assert_equal [TX_HASH], params
      receipt
    end
    Mpp::Methods::Tempo::Rpc.stub(:call, rpc, &block)
  end

  def topic_address(address)
    "0x#{address.delete_prefix("0x").downcase.rjust(64, "0")}"
  end
end
