# typed: false
# frozen_string_literal: true

require_relative "defaults"
require_relative "transaction"

module Mpp
  module Methods
    module Tempo
      DEFAULT_GAS_LIMIT = 1_000_000
      EXPIRING_NONCE_KEY = (1 << 256) - 1 # U256::MAX
      FEE_PAYER_VALID_BEFORE_SECS = 25

      class TransactionError < StandardError; end

      # Tempo payment method implementation.
      # Handles client-side credential creation for Tempo payments.
      class TempoMethod
        attr_reader :name, :account, :fee_payer, :root_account, :rpc_url,
          :chain_id, :currency, :recipient, :decimals, :client_id,
          :expected_recipients
        attr_accessor :intents

        def initialize(account: nil, fee_payer: nil, root_account: nil,
          rpc_url: Defaults::RPC_URL, chain_id: nil, currency: nil,
          recipient: nil, decimals: 6, client_id: nil,
          expected_recipients: nil)
          @name = "tempo"
          @account = account
          @fee_payer = fee_payer
          @root_account = root_account
          @rpc_url = rpc_url
          @chain_id = chain_id
          @currency = currency
          @recipient = recipient
          @decimals = decimals
          @client_id = client_id
          @expected_recipients = expected_recipients&.map(&:downcase)&.to_set
          @intents = {}
        end

        # Create a credential to satisfy the given challenge.
        #
        # mode: :pull (default) — return signed transaction for server to broadcast
        #        :push — broadcast on-chain, return transaction hash
        #        :proof — zero-amount transaction proving account ownership
        def create_credential(challenge, mode: nil)
          raise ArgumentError, "No account configured for signing" unless @account
          raise ArgumentError, "Unsupported intent: #{challenge.intent}" unless challenge.intent == "charge"

          mode ||= :pull
          request = challenge.request
          method_details = request["methodDetails"]
          method_details = {} unless method_details.is_a?(Hash)

          validate_recipients(request, method_details) if @expected_recipients

          use_fee_payer = method_details.fetch("feePayer", false)

          nonce_key = request.fetch("nonce_key", 0)
          if nonce_key.is_a?(String)
            nonce_key = nonce_key.start_with?("0x") ? nonce_key.to_i(16) : nonce_key.to_i
          end

          memo = method_details["memo"]
          memo ||= Attribution.encode(server_id: challenge.realm, client_id: @client_id, challenge_id: challenge.id)

          # Resolve RPC URL from challenge's chainId
          resolved_rpc_url = @rpc_url
          expected_chain_id = nil
          challenge_chain_id = method_details["chainId"]
          if challenge_chain_id
            begin
              parsed_chain_id = Integer(challenge_chain_id)
              resolved = Defaults::CHAIN_RPC_URLS[parsed_chain_id]
              if resolved
                resolved_rpc_url = resolved
                expected_chain_id = parsed_chain_id
              end
            rescue ArgumentError, TypeError
              # ignore
            end
          end

          expected_chain_id ||= @chain_id

          # Proof mode: sign EIP-712 typed data (no transaction needed)
          if mode == :proof
            chain_id = expected_chain_id || @chain_id
            raise ArgumentError, "chain_id required for proof mode" unless chain_id

            signature = Proof.sign(
              account: @account,
              chain_id: chain_id,
              challenge_id: challenge.id
            )

            return Mpp::Credential.new(
              challenge: challenge.to_echo,
              payload: {"type" => "proof", "signature" => signature},
              source: Proof.source(address: @account.address, chain_id: chain_id)
            )
          end

          raw_tx, chain_id = build_tempo_transfer(
            amount: request["amount"],
            currency: request["currency"],
            recipient: request["recipient"],
            nonce_key: nonce_key,
            memo: memo,
            rpc_url: resolved_rpc_url,
            expected_chain_id: expected_chain_id,
            awaiting_fee_payer: use_fee_payer
          )

          payload = if mode == :push
            tx_hash = Rpc.call(resolved_rpc_url, "eth_sendRawTransaction", [raw_tx])
            raise TransactionError, "No transaction hash returned" unless tx_hash
            {"type" => "hash", "hash" => tx_hash}
          else
            {"type" => "transaction", "signature" => raw_tx}
          end

          Mpp::Credential.new(
            challenge: challenge.to_echo,
            payload: payload,
            source: "did:pkh:eip155:#{chain_id}:#{@account.address}"
          )
        end

        # Transform request - adds default methodDetails if needed.
        def transform_request(request, _credential)
          request
        end

        private

        def validate_recipients(request, method_details)
          recipient = request["recipient"]
          if recipient && !@expected_recipients.include?(recipient.downcase)
            raise ArgumentError, "Unexpected recipient: #{recipient}"
          end

          splits = method_details["splits"]
          return unless splits.is_a?(Array)

          splits.each do |split|
            addr = split["recipient"]
            next unless addr
            unless @expected_recipients.include?(addr.downcase)
              raise ArgumentError, "Unexpected split recipient: #{addr}"
            end
          end
        end

        def build_tempo_transfer(amount:, currency:, recipient:, nonce_key: 0,
          memo: nil, rpc_url: nil, expected_chain_id: nil,
          awaiting_fee_payer: false)
          raise ArgumentError, "No account configured" unless @account

          resolved_rpc = rpc_url || @rpc_url

          transfer_data = if memo
            encode_transfer_with_memo(recipient, Integer(amount), memo)
          else
            encode_transfer(recipient, Integer(amount))
          end

          chain_id, on_chain_nonce, gas_price = Rpc.get_tx_params(resolved_rpc, @account.address)

          if expected_chain_id && chain_id != expected_chain_id
            raise TransactionError,
              "Chain ID mismatch: RPC returned #{chain_id}, expected #{expected_chain_id} from challenge"
          end

          if awaiting_fee_payer
            resolved_nonce_key = EXPIRING_NONCE_KEY
            resolved_nonce = 0
            valid_before = Time.now.to_i + FEE_PAYER_VALID_BEFORE_SECS
          else
            resolved_nonce_key = nonce_key
            resolved_nonce = on_chain_nonce
            valid_before = nil
          end

          gas_limit = DEFAULT_GAS_LIMIT
          begin
            estimated = Rpc.estimate_gas(resolved_rpc, @account.address, currency, transfer_data)
            gas_limit = [gas_limit, estimated + 5_000].max
          rescue
            # fallback to default
          end
          Transaction.build_signed_transfer(
            account: @account,
            chain_id: chain_id,
            gas_limit: gas_limit,
            gas_price: gas_price,
            nonce: resolved_nonce,
            nonce_key: resolved_nonce_key,
            currency: currency,
            transfer_data: transfer_data,
            valid_before: valid_before,
            awaiting_fee_payer: awaiting_fee_payer
          )
        rescue LoadError => e
          raise TransactionError, e.message
        end

        def encode_transfer(to, amount)
          selector = "a9059cbb"
          to_padded = to.delete_prefix("0x").downcase.rjust(64, "0")
          amount_padded = amount.to_s(16).rjust(64, "0")
          "0x#{selector}#{to_padded}#{amount_padded}"
        end

        def encode_transfer_with_memo(to, amount, memo)
          selector = "95777d59"
          to_padded = to.delete_prefix("0x").downcase.rjust(64, "0")
          amount_padded = amount.to_s(16).rjust(64, "0")
          memo_clean = memo.delete_prefix("0x")
          unless memo_clean.length == 64
            raise ArgumentError,
              "memo must be exactly 32 bytes (64 hex chars), got #{memo_clean.length}"
          end

          "0x#{selector}#{to_padded}#{amount_padded}#{memo_clean.downcase}"
        end
      end

      # Factory function to create a configured TempoMethod.
      def self.tempo(intents:, account: nil, fee_payer: nil, chain_id: nil, rpc_url: nil,
        root_account: nil, currency: nil, recipient: nil, decimals: 6, client_id: nil,
        expected_recipients: nil)
        rpc_url ||= chain_id ? Defaults.rpc_url_for_chain(chain_id) : Defaults::RPC_URL
        currency ||= Defaults.default_currency_for_chain(chain_id)

        method = TempoMethod.new(
          account: account,
          fee_payer: fee_payer,
          rpc_url: rpc_url,
          chain_id: chain_id,
          root_account: root_account,
          currency: currency,
          recipient: recipient,
          decimals: decimals,
          client_id: client_id,
          expected_recipients: expected_recipients
        )

        intents.each_value do |intent|
          intent.rpc_url = rpc_url if intent.respond_to?(:rpc_url=) && intent.rpc_url.nil?
          intent.instance_variable_set(:@_method, method) if intent.respond_to?(:fee_payer)
        end
        method.intents = intents.dup
        method
      end
    end
  end
end
