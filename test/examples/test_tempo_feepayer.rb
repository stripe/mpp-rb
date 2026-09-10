# frozen_string_literal: true

require "test_helper"
require "json"
require "webmock/minitest"
require_relative "../../examples/tempo_feepayer/handler"

class TestTempoFeepayerExample < Minitest::Test
  RAW_TX = "0xabcdef1234567890"
  CURRENCY = Mpp::Methods::Tempo::Defaults::PATH_USD
  RECIPIENT = "0x#{"0" * 39}1"
  SENDER = "0x#{"0" * 38}aa"
  AMOUNT = 10_000
  RPC_URL = "https://rpc.example.test"
  SPONSOR_URL = "https://sponsor.example.test"

  def setup
    ENV["TEMPO_RPC_URL"] = RPC_URL
    ENV["FEE_PAYER_URL"] = SPONSOR_URL
    ENV["FEE_PAYER_TOKEN"] = "test-fee-payer-token"
    ENV["RECIPIENT_ADDRESS"] = RECIPIENT
    ENV["SECRET_KEY"] = "example-secret"
    ENV["MPP_REALM"] = "localhost:4567"
    @server = TempoFeepayerExample.handler
  end

  def test_paid_challenge_advertises_fee_payer
    challenge = @server.charge(nil, "0.01", description: "Paid endpoint")

    assert_instance_of Mpp::Challenge, challenge
    assert challenge.request.dig("methodDetails", "feePayer")
    assert_equal Mpp::Methods::Tempo::Defaults::TESTNET_CHAIN_ID,
      challenge.request.dig("methodDetails", "chainId")
    refute challenge.request.dig("methodDetails", "feePayerUrl")
  end

  def test_paid_charge_sends_fee_payer_headers_and_broadcasts
    challenge = @server.charge(nil, "0.01", description: "Paid endpoint")
    tx_hash = raw_transaction_hash(RAW_TX)
    memo = Mpp::Methods::Tempo::Attribution.encode(
      server_id: challenge.realm,
      challenge_id: challenge.id
    )

    stub_request(:post, "#{SPONSOR_URL}/")
      .with { |request|
        body = JSON.parse(request.body)
        request.headers["Authorization"] == "Bearer test-fee-payer-token" &&
          body["method"] == "eth_signRawTransaction" &&
          body["params"] == [RAW_TX]
      }
      .to_return(status: 200, body: {jsonrpc: "2.0", result: RAW_TX, id: 1}.to_json)

    stub_request(:post, RPC_URL)
      .to_return { |request|
        body = JSON.parse(request.body)
        case body["method"]
        when "eth_sendRawTransaction"
          {status: 200, body: {jsonrpc: "2.0", result: tx_hash, id: 1}.to_json}
        when "eth_getTransactionReceipt"
          {status: 200, body: {jsonrpc: "2.0", result: receipt_for(memo), id: 1}.to_json}
        else
          {status: 500, body: {error: "unexpected #{body["method"]}"}.to_json}
        end
      }

    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "transaction", "signature" => RAW_TX}
    )
    result = @server.charge(credential.to_authorization, "0.01", description: "Paid endpoint")

    refute_instance_of Mpp::Challenge, result
    _credential, receipt = result
    assert_equal tx_hash, receipt.reference
    assert_requested :post, "#{SPONSOR_URL}/",
      headers: {"Authorization" => "Bearer test-fee-payer-token"}
  end

  def test_paid_charge_rejects_missing_fee_payer_auth
    challenge = @server.charge(nil, "0.01", description: "Paid endpoint")
    stub_request(:post, "#{SPONSOR_URL}/")
      .to_return(status: 401, body: {error: "unauthorized"}.to_json)

    credential = Mpp::Credential.new(
      challenge: challenge.to_echo,
      payload: {"type" => "transaction", "signature" => RAW_TX}
    )

    error = assert_raises(Mpp::VerificationFailedError) do
      @server.charge(credential.to_authorization, "0.01", description: "Paid endpoint")
    end
    assert_match(/HTTP 401/, error.message)
  end

  private

  def raw_transaction_hash(raw_tx)
    require "eth"

    "0x#{Eth::Util.keccak256([raw_tx.delete_prefix("0x")].pack("H*")).unpack1("H*")}"
  end

  def receipt_for(memo)
    {
      "status" => "0x1",
      "from" => SENDER,
      "logs" => [{
        "address" => CURRENCY,
        "topics" => [
          Mpp::Methods::Tempo::TRANSFER_WITH_MEMO_TOPIC,
          "0x#{SENDER.delete_prefix("0x").rjust(64, "0")}",
          "0x#{RECIPIENT.delete_prefix("0x").rjust(64, "0")}",
          memo
        ],
        "data" => "0x#{AMOUNT.to_s(16).rjust(64, "0")}"
      }]
    }
  end
end
