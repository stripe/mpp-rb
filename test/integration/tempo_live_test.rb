# frozen_string_literal: true

require "test_helper"
require "json"
require "net/http"
require "securerandom"
require "socket"

class TempoLiveIntegrationTest < Minitest::Test
  RPC_URL = ENV.fetch("TEMPO_RPC_URL", "http://localhost:8545")
  REALM = "mpp-rb.local"
  SECRET_KEY = "integration-secret"
  CURRENCY = Mpp::Methods::Tempo::Defaults::PATH_USD
  FUNDING_TIMEOUT = 45
  RECEIPT_TIMEOUT = 45

  def setup
    skip "TEMPO_RPC_URL not set" unless ENV["TEMPO_RPC_URL"]

    wait_for_rpc
  end

  def test_transaction_credential_verifies_against_live_node
    payer = funded_account
    recipient = funded_account
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: REALM, challenge_id: "tx-#{SecureRandom.hex(6)}")
    challenge = challenge_for(recipient: recipient.address, memo: memo)

    credential = client_method(account: payer).create_credential(challenge)
    receipt = charge_intent.verify(credential, challenge.request)

    assert_equal "success", receipt.status
    assert_equal "tempo", receipt.method
    assert_match(/\A0x[0-9a-fA-F]{64}\z/, receipt.reference)
  end

  def test_client_transport_completes_402_roundtrip
    payer = funded_account
    recipient = funded_account
    server = PaidServer.new(recipient: recipient.address, chain_id: chain_id)

    response = Mpp::Client.get(server.url, methods: [client_method(account: payer)])

    assert_equal "200", response.code
    refute_nil response["Payment-Receipt"]
    body = JSON.parse(response.body)
    assert_equal "paid", body.fetch("status")
  ensure
    server&.close
  end

  def test_hash_credential_verifies_live_transfer
    payer = funded_account
    recipient = funded_account
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: REALM, challenge_id: "hash-#{SecureRandom.hex(6)}")
    challenge = challenge_for(recipient: recipient.address, memo: memo)
    tx_hash = send_transfer(
      account: payer,
      recipient: recipient.address,
      amount: 1_000_000,
      memo: memo
    )
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "hash", "hash" => tx_hash},
      source: "did:pkh:eip155:#{chain_id}:#{payer.address}"
    )

    receipt = charge_intent.verify(credential, challenge.request)

    assert_equal "success", receipt.status
    assert_equal tx_hash, receipt.reference
  end

  def test_hash_credential_replay_rejected_with_store
    payer = funded_account
    recipient = funded_account
    memo = Mpp::Methods::Tempo::Attribution.encode(server_id: REALM, challenge_id: "replay-#{SecureRandom.hex(6)}")
    challenge = challenge_for(recipient: recipient.address, memo: memo)
    tx_hash = send_transfer(
      account: payer,
      recipient: recipient.address,
      amount: 1_000_000,
      memo: memo
    )
    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "hash", "hash" => tx_hash},
      source: "did:pkh:eip155:#{chain_id}:#{payer.address}"
    )
    intent = charge_intent(store: Mpp::MemoryStore.new)

    receipt = intent.verify(credential, challenge.request)
    assert_equal "success", receipt.status

    error = assert_raises(Mpp::VerificationError) do
      intent.verify(credential, challenge.request)
    end
    assert_match(/already used/, error.message)
  end

  private

  def chain_id
    @chain_id ||= rpc("eth_chainId").to_i(16)
  end

  def wait_for_rpc
    deadline = Time.now + 45
    loop do
      begin
        return if rpc("eth_chainId")
      rescue
        nil
      end

      raise "Tempo RPC at #{RPC_URL} did not become ready" if Time.now >= deadline

      sleep 0.5
    end
  end

  def rpc(method, params = [])
    Mpp::Methods::Tempo::Rpc.call(RPC_URL, method, params)
  end

  def funded_account
    account = Mpp::Methods::Tempo::Account.from_key("0x#{SecureRandom.hex(32)}")
    fund_account(account.address)
    account
  end

  def fund_account(address)
    result = rpc("tempo_fundAddress", [address])
    wait_for_receipt(result) if result.is_a?(String) && !result.empty?
    wait_for_balance(address)
  rescue => _e
    wait_for_balance(address)
  end

  def wait_for_balance(address)
    deadline = Time.now + FUNDING_TIMEOUT
    loop do
      return if token_balance(address).positive?

      raise "Account #{address} was not funded" if Time.now >= deadline

      sleep 0.5
    end
  end

  def token_balance(address)
    data = "0x70a08231#{address.delete_prefix("0x").downcase.rjust(64, "0")}"
    rpc("eth_call", [{"to" => CURRENCY, "data" => data}, "latest"]).to_i(16)
  end

  def wait_for_receipt(tx_hash)
    deadline = Time.now + RECEIPT_TIMEOUT
    loop do
      receipt = rpc("eth_getTransactionReceipt", [tx_hash])
      return receipt if receipt && receipt["status"] == "0x1"
      raise "Transaction #{tx_hash} did not succeed" if receipt
      raise "Receipt not found for #{tx_hash}" if Time.now >= deadline

      sleep 0.5
    end
  end

  def send_transfer(account:, recipient:, amount:, memo:)
    raw_tx = build_raw_transfer(account: account, recipient: recipient, amount: amount, memo: memo)
    tx_hash = rpc("eth_sendRawTransaction", [raw_tx])
    wait_for_receipt(tx_hash)
    tx_hash
  end

  def build_raw_transfer(account:, recipient:, amount:, memo:)
    tx_params = Mpp::Methods::Tempo::Rpc.get_tx_params(RPC_URL, account.address)
    chain_id, nonce, gas_price = tx_params
    data = encode_transfer_with_memo(recipient, amount, memo)

    raw_tx, = Mpp::Methods::Tempo::Transaction.build_signed_transfer(
      account: account,
      chain_id: chain_id,
      gas_limit: 1_000_000,
      gas_price: gas_price,
      nonce: nonce,
      nonce_key: 0,
      currency: CURRENCY,
      transfer_data: data
    )
    raw_tx
  end

  def encode_transfer_with_memo(recipient, amount, memo)
    to_padded = recipient.delete_prefix("0x").downcase.rjust(64, "0")
    amount_padded = amount.to_s(16).rjust(64, "0")
    memo_clean = memo.delete_prefix("0x").downcase
    "0x95777d59#{to_padded}#{amount_padded}#{memo_clean}"
  end

  def client_method(account:)
    Mpp::Methods::Tempo.tempo(
      account: account,
      chain_id: chain_id,
      rpc_url: RPC_URL,
      intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new}
    )
  end

  def charge_intent(store: nil)
    Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: RPC_URL, store: store)
  end

  def challenge_for(recipient:, memo: nil)
    method_details = {"chainId" => chain_id}
    method_details["memo"] = memo if memo

    Mpp::Challenge.create(
      secret_key: SECRET_KEY,
      realm: REALM,
      method: "tempo",
      intent: "charge",
      request: {
        "amount" => "1000000",
        "currency" => CURRENCY,
        "recipient" => recipient,
        "methodDetails" => method_details
      },
      expires: Mpp::Expires.minutes(5)
    )
  end

  class PaidServer
    attr_reader :url

    def initialize(recipient:, chain_id:)
      method = Mpp::Methods::Tempo.tempo(
        chain_id: chain_id,
        rpc_url: RPC_URL,
        currency: CURRENCY,
        recipient: recipient,
        intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new(rpc_url: RPC_URL)}
      )
      @handler = Mpp.create(method: method, realm: REALM, secret_key: SECRET_KEY)
      @memo = Mpp::Methods::Tempo::Attribution.encode(server_id: REALM, challenge_id: SecureRandom.hex(6))
      @server = TCPServer.new("127.0.0.1", 0)
      @url = "http://127.0.0.1:#{@server.addr[1]}/paid"
      @thread = Thread.new { serve }
    end

    def close
      @server.close
      @thread.join(2)
    end

    private

    def serve
      loop do
        socket = @server.accept
        handle(socket)
      rescue IOError
        break
      end
    end

    def handle(socket)
      request_line = socket.gets
      return unless request_line

      headers = {}
      while (line = socket.gets)
        line = line.strip
        break if line.empty?

        key, value = line.split(":", 2)
        headers[key.downcase] = value.strip if key && value
      end

      result = @handler.charge(headers["authorization"], "1.00", chain_id: chain_id, memo: @memo)
      if result.is_a?(Mpp::Challenge)
        response = Mpp::Server::Decorator.make_challenge_response(result, @handler.realm)
        write_response(socket, response["status"], response["headers"], response["body"])
      else
        _credential, receipt = result
        body = JSON.generate({"status" => "paid"})
        write_response(socket, 200, {
          "Content-Type" => "application/json",
          "Payment-Receipt" => receipt.to_payment_receipt
        }, body)
      end
    rescue => e
      write_response(socket, 500, {"Content-Type" => "text/plain"}, e.message)
    ensure
      socket&.close
    end

    def chain_id
      @handler.method.chain_id
    end

    def write_response(socket, status, headers, body)
      reason = (status == 200) ? "OK" : "Payment Required"
      socket.write("HTTP/1.1 #{status} #{reason}\r\n")
      headers.each { |key, value| socket.write("#{key}: #{value}\r\n") }
      socket.write("Content-Length: #{body.bytesize}\r\n")
      socket.write("Connection: close\r\n")
      socket.write("\r\n")
      socket.write(body)
    end
  end
end
