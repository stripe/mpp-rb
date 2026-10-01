# typed: false
# frozen_string_literal: true

require_relative "defaults"
require_relative "fee_payer_policy"
require_relative "rlp"
require_relative "rpc"
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
        COMPLETED_TRANSACTION_PATTERN = /\A0x76(?:[0-9a-fA-F]{2})+\z/

        attr_reader :name, :account, :fee_payer, :fee_payer_allowed_fee_tokens,
          :root_account, :chain_id, :currency, :currencies, :recipient, :decimals, :client_id,
          :expected_recipients, :relay, :on_payment_success, :rlp, :rpc,
          :transaction_fee_payer, :nonce_strategy, :valid_before, :fee_token
        attr_accessor :intents

        def initialize(account: nil, fee_payer: nil, root_account: nil,
          rpc_url: nil, rpc: nil, rlp: nil, chain_id: nil, currency: nil,
          recipient: nil, decimals: 6, client_id: nil,
          expected_recipients: nil, fee_payer_allowed_fee_tokens: nil,
          relay: nil, on_payment_success: nil, can_offer: nil,
          transaction_fee_payer: nil, nonce_strategy: :sequential, valid_before: nil,
          currencies: nil, fee_token: nil)
          unless on_payment_success.nil? || on_payment_success.respond_to?(:call)
            raise ArgumentError, "on_payment_success must be callable"
          end
          if !can_offer.nil? && !can_offer.respond_to?(:call)
            raise ArgumentError, "can_offer must be callable"
          end
          unless [:sequential, :expiring].include?(nonce_strategy)
            raise ArgumentError, "unknown nonce strategy: #{nonce_strategy.inspect}"
          end
          if transaction_fee_payer && !transaction_fee_payer.respond_to?(:cosign)
            raise ArgumentError, "transaction_fee_payer must respond to cosign(raw_transaction)"
          end

          @name = "tempo"
          @account = account
          @fee_payer = fee_payer
          @relay = relay
          @fee_token = fee_token
          @fee_payer_allowed_fee_tokens =
            fee_payer_allowed_fee_tokens&.map { |token| token.to_s.downcase }
          @root_account = root_account
          @rpc_url = rpc_url
          @rpc = Rpc.resolve(rpc)
          @rlp = Rlp.resolve(rlp)
          @transaction_fee_payer = transaction_fee_payer
          @nonce_strategy = nonce_strategy
          @valid_before = valid_before
          @chain_id = chain_id
          # Ordered currencies offered by a server; the first is the primary.
          @currencies = (currencies || [currency].compact).dup.freeze
          @currency = currency || @currencies.first
          @recipient = recipient
          @decimals = decimals
          @client_id = client_id
          @expected_recipients = expected_recipients&.map(&:downcase)&.to_set
          @on_payment_success = on_payment_success
          @can_offer = can_offer
          @intents = {}
        end

        def can_offer?(request)
          return true unless @can_offer

          @can_offer.call(request)
        end

        # Resolve an endpoint for the configured chain, or a challenge-provided override.
        # An explicitly configured URL always takes precedence.
        def rpc_url(chain_id: nil)
          return @rpc_url if @rpc_url

          resolved_chain_id = chain_id || @chain_id
          return Defaults::RPC_URL unless resolved_chain_id

          Defaults::CHAIN_RPC_URLS[Integer(resolved_chain_id)] || Defaults::RPC_URL
        rescue ArgumentError, TypeError
          Defaults::RPC_URL
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

          # Resolve RPC URL from challenge's chainId. Normalize the configured pin
          # once (it may be a String from ENV/config) so it compares equal to
          # integer chain ids everywhere, including the downstream RPC check.
          expected_chain_id = nil
          configured_chain_id = @chain_id.nil? ? nil : Integer(@chain_id)
          challenge_chain_id = method_details["chainId"]
          if challenge_chain_id
            begin
              parsed_chain_id = Integer(challenge_chain_id)
              # Chain pinning: reject a challenge whose chainId conflicts with the
              # configured chain, before any RPC call or signing.
              if configured_chain_id && parsed_chain_id != configured_chain_id
                raise TransactionError, "Chain ID mismatch: expected #{configured_chain_id}, got #{parsed_chain_id}"
              end
              expected_chain_id = parsed_chain_id
            rescue ArgumentError, TypeError
              # ignore
            end
          end

          expected_chain_id ||= configured_chain_id
          resolved_rpc_url = rpc_url(chain_id: expected_chain_id)

          # Proof mode: sign EIP-712 typed data (no transaction needed)
          if mode == :proof
            chain_id = expected_chain_id || @chain_id
            raise ArgumentError, "chain_id required for proof mode" unless chain_id

            signature = Proof.sign(
              account: @account,
              chain_id: chain_id,
              challenge_id: challenge.id,
              realm: challenge.realm
            )

            return Mpp::Credential.new(
              challenge: challenge.to_echo,
              payload: {"type" => "proof", "signature" => signature},
              source: Proof.source(address: @account.address, chain_id: chain_id)
            )
          end

          server_fee_payer = method_details.fetch("feePayer", false) == true
          client_fee_payer = @transaction_fee_payer unless server_fee_payer
          awaiting_fee_payer = server_fee_payer || client_fee_payer

          nonce_key = request.fetch("nonce_key", 0)
          if nonce_key.is_a?(String)
            nonce_key = nonce_key.start_with?("0x") ? nonce_key.to_i(16) : nonce_key.to_i
          end
          resolved_nonce_strategy = server_fee_payer ? :expiring : @nonce_strategy

          memo = Attribution.encode(server_id: challenge.realm, client_id: @client_id, challenge_id: challenge.id)

          raw_tx, chain_id = build_tempo_transfer(
            amount: request["amount"],
            currency: request["currency"],
            recipient: request["recipient"],
            nonce_key: nonce_key,
            memo: memo,
            rpc_url: resolved_rpc_url,
            expected_chain_id: expected_chain_id,
            awaiting_fee_payer: awaiting_fee_payer,
            nonce_strategy: resolved_nonce_strategy,
            challenge: challenge
          )
          raw_tx = complete_client_sponsorship(raw_tx, client_fee_payer) if client_fee_payer

          payload = if mode == :push
            tx_hash = @rpc.call(resolved_rpc_url, "eth_sendRawTransaction", [raw_tx])
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

        def validate_signer!(signer, name)
          unless signer.respond_to?(:address) && signer.respond_to?(:sign_hash)
            raise ArgumentError, "#{name} must respond to address and sign_hash"
          end
        end

        def complete_client_sponsorship(raw_tx, fee_payer)
          completed = fee_payer.cosign(raw_tx)
          unless completed.is_a?(String) && completed.match?(COMPLETED_TRANSACTION_PATTERN)
            raise TransactionError, "transaction_fee_payer must return a completed 0x76 transaction"
          end

          completed
        end

        def resolve_valid_before(challenge, strategy)
          return nil unless strategy == :expiring

          value = if @valid_before.respond_to?(:call)
            @valid_before.call(challenge: challenge)
          elsif @valid_before.nil?
            Time.now.to_i + FEE_PAYER_VALID_BEFORE_SECS
          else
            @valid_before
          end

          unless value.is_a?(Integer) && value > Time.now.to_i
            raise ArgumentError, "valid_before must be an integer timestamp in the future"
          end

          value
        end

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
          awaiting_fee_payer: false, nonce_strategy: nil, challenge: nil)
          raise ArgumentError, "No account configured" unless @account
          validate_signer!(@account, "account")

          resolved_rpc = rpc_url || self.rpc_url

          transfer_data = if memo
            encode_transfer_with_memo(recipient, Integer(amount), memo)
          else
            encode_transfer(recipient, Integer(amount))
          end

          chain_id, on_chain_nonce, gas_price = Rpc.get_tx_params(
            resolved_rpc,
            @account.address,
            provider: @rpc
          )

          if expected_chain_id && chain_id != expected_chain_id
            raise TransactionError,
              "Chain ID mismatch: RPC returned #{chain_id}, expected #{expected_chain_id} from challenge"
          end
          if awaiting_fee_payer
            policy = FeePayerPolicy.for_chain_id(chain_id)
            max_fee_per_gas = [gas_price, policy.max_fee_per_gas].min
            max_priority_fee_per_gas = [gas_price, policy.max_priority_fee_per_gas].min
          end

          resolved_nonce_strategy = nonce_strategy || (awaiting_fee_payer ? :expiring : :sequential)
          if resolved_nonce_strategy == :expiring
            resolved_nonce_key = EXPIRING_NONCE_KEY
            resolved_nonce = 0
          else
            resolved_nonce_key = nonce_key
            resolved_nonce = on_chain_nonce
          end

          gas_limit = DEFAULT_GAS_LIMIT
          begin
            estimated = Rpc.estimate_gas(
              resolved_rpc,
              @account.address,
              currency,
              transfer_data,
              provider: @rpc
            )
            gas_limit = [gas_limit, estimated + 5_000].max
          rescue
            # fallback to default
          end
          resolved_valid_before = resolve_valid_before(challenge, resolved_nonce_strategy)
          Transaction.build_signed_transfer(
            account: @account,
            chain_id: chain_id,
            gas_limit: gas_limit,
            gas_price: gas_price,
            max_priority_fee_per_gas: max_priority_fee_per_gas,
            max_fee_per_gas: max_fee_per_gas,
            nonce: resolved_nonce,
            nonce_key: resolved_nonce_key,
            currency: currency,
            transfer_data: transfer_data,
            valid_before: resolved_valid_before,
            awaiting_fee_payer: awaiting_fee_payer,
            rlp: @rlp
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
      #
      # A server offers one charge per accepted currency, in order. Without
      # `currencies:` it offers OUSD then USDC.e on mainnet and OUSD then
      # pathUSD on Moderato; other chains keep their single default.
      # `currencies:` replaces the defaults. The deprecated `currency:` accepts
      # exactly that token. `currency` keeps its previous default for clients.
      #
      # A local fee payer pays gas in `fee_token:` when set, else in the first
      # allowed fee token it holds, independent of the charge currency.
      def self.tempo(intents:, account: nil, fee_payer: nil, chain_id: Defaults::CHAIN_ID, rpc_url: nil,
        root_account: nil, currency: nil, recipient: nil, decimals: 6, client_id: nil,
        expected_recipients: nil, fee_payer_allowed_fee_tokens: nil, relay: nil,
        on_payment_success: nil, can_offer: nil, rlp: nil, rpc: nil,
        transaction_fee_payer: nil, nonce_strategy: :sequential, valid_before: nil,
        currencies: nil, fee_token: nil)
        rpc_url ||= Defaults.rpc_url_for_chain(Integer(chain_id)) if chain_id

        if fee_payer == true
          raise ArgumentError, "fee_payer: true requires account:" unless account

          fee_payer = account
        end
        fee_payer = FeePayerClient.resolve_optional(fee_payer)
        if fee_token && (fee_payer.nil? || FeePayerClient.hosted_config?(fee_payer))
          raise ArgumentError, "fee_token can only be configured for a local fee payer"
        end

        if fee_token && !Defaults::ADDRESS_PATTERN.match?(fee_token)
          raise ArgumentError, "Invalid Tempo fee token address: #{fee_token.inspect}"
        end
        if fee_payer_allowed_fee_tokens&.empty?
          raise ArgumentError, "fee_payer_allowed_fee_tokens must contain at least one token"
        end

        legacy_currency = Defaults.default_currency_for_chain(chain_id)
        primary_currency = currency || currencies&.first || legacy_currency
        # `currency:` is deprecated in favor of `currencies: [currency]`.
        currencies = Defaults.accepted_currencies(chain_id: chain_id, currency: currency, currencies: currencies)

        method = TempoMethod.new(
          account: account,
          fee_payer: fee_payer,
          rpc_url: rpc_url,
          rpc: rpc,
          rlp: rlp,
          chain_id: chain_id,
          root_account: root_account,
          currency: primary_currency,
          currencies: currencies,
          recipient: recipient,
          decimals: decimals,
          client_id: client_id,
          expected_recipients: expected_recipients,
          fee_payer_allowed_fee_tokens: fee_payer_allowed_fee_tokens,
          relay: Relay.resolve_optional(relay),
          on_payment_success: on_payment_success,
          can_offer: can_offer,
          transaction_fee_payer: transaction_fee_payer,
          nonce_strategy: nonce_strategy,
          valid_before: valid_before,
          fee_token: fee_token
        )

        intents.each_value do |intent|
          intent.rpc_url = method.rpc_url if intent.respond_to?(:rpc_url=) && intent.rpc_url.nil?
          if intent.respond_to?(:fee_payer) || intent.respond_to?(:relay)
            intent.instance_variable_set(:@_method, method)
          end
        end
        method.intents = intents.dup
        method
      end
    end
  end
end
