# typed: false
# frozen_string_literal: true

require "time"
require "json"

module Mpp
  module Methods
    module Tempo
      MAX_RECEIPT_RETRY_ATTEMPTS = 20
      RECEIPT_RETRY_DELAY_SECONDS = 0.5

      TRANSFER_SELECTOR = "a9059cbb"
      TRANSFER_WITH_MEMO_SELECTOR = "95777d59"
      TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
      TRANSFER_WITH_MEMO_TOPIC = "0x57bc7354aa85aed339e000bccffabbc529466af35f0772c8f8ee1145927de7f0"
      TRANSACTION_PENDING = "transaction:pending"
      TRANSACTION_VERIFIED = "transaction:verified"

      # Tempo charge intent for server-side verification.
      class ChargeIntent
        attr_reader :name
        attr_accessor :rpc_url

        def initialize(chain_id: nil, rpc_url: nil, timeout: 30, store: nil, validate_sender: nil)
          @name = "charge"
          @rpc_url = rpc_url || (chain_id ? Defaults.rpc_url_for_chain(chain_id) : nil)
          @_method = nil
          @timeout = timeout
          @store = store
          @validate_sender = validate_sender
        end

        def fee_payer
          @_method&.fee_payer
        end

        def fee_payer_allowed_fee_tokens
          @_method&.fee_payer_allowed_fee_tokens
        end

        def relay
          @_method&.relay
        end

        def verify(credential, request)
          req = Schemas::ChargeRequest.from_hash(request)

          # Check challenge expiry
          challenge_expires = credential.challenge.expires
          if challenge_expires
            expires = Time.iso8601(challenge_expires.gsub("Z", "+00:00"))
            raise Mpp::VerificationError, "Request has expired" if expires < Time.now.utc
          end

          return relay.verify(credential, request) if relay

          payload_data = credential.payload
          unless payload_data.is_a?(Hash) && payload_data.key?("type")
            raise Mpp::VerificationError,
              "Invalid credential payload"
          end

          case payload_data["type"]
          when "hash"
            payload = Schemas::HashCredentialPayload.new(type: "hash", hash: payload_data["hash"])
            verify_hash(payload, req, credential: credential)
          when "transaction"
            payload = Schemas::TransactionCredentialPayload.new(
              type: "transaction", signature: payload_data["signature"]
            )
            verify_transaction(payload, req, credential: credential)
          when "proof"
            payload = Schemas::ProofCredentialPayload.new(
              type: "proof", signature: payload_data["signature"]
            )
            verify_proof(payload, req, credential: credential)
          else
            raise Mpp::VerificationError, "Invalid credential type: #{payload_data["type"]}"
          end
        end

        private

        def get_rpc_url
          raise Mpp::VerificationError, "No rpc_url configured on ChargeIntent" unless @rpc_url

          @rpc_url
        end

        # Parse a hash credential source: nil if absent, the address for a
        # did:pkh:eip155 DID matching expected_chain_id, else raises.
        def parse_hash_credential_source(source, expected_chain_id)
          return nil unless source

          expected_chain_id = begin
            Integer(expected_chain_id)
          rescue ArgumentError, TypeError
            raise Mpp::VerificationError, "Hash credential source is invalid"
          end

          parsed = Proof.parse_source(source)
          unless parsed && parsed[:chain_id] == expected_chain_id
            raise Mpp::VerificationError, "Hash credential source is invalid"
          end

          parsed[:address]
        end

        def verify_hash(payload, request, credential:)
          # Validate the source before reserving the hash.
          source_address = parse_hash_credential_source(credential.source, request.method_details.chain_id)

          if @store
            store_key = "mpp:charge:#{payload.hash.downcase}"
            raise Mpp::VerificationError, "Transaction hash already used" unless @store.put_if_absent(store_key,
              payload.hash)
          end

          rpc_url = get_rpc_url
          result = Rpc.call(rpc_url, "eth_getTransactionReceipt", [payload.hash])

          raise Mpp::VerificationError, "Transaction not found" unless result
          raise Mpp::VerificationError, "Transaction reverted" unless result["status"] == "0x1"

          # Use the source address if present, otherwise the receipt sender.
          # The sender override only applies when a source was declared; without
          # one, the legacy receipt["from"] match must hold unconditionally.
          expected_sender = source_address || result["from"]
          matched_logs = match_transfer_logs(result, request, expected_sender: expected_sender,
            source: credential.source, validate_sender: source_address ? @validate_sender : nil)
          unless matched_logs.any?
            raise Mpp::VerificationError,
              "Transaction must contain a Transfer log matching request parameters"
          end
          assert_challenge_bound_memo(matched_logs, credential.challenge) unless request.method_details.memo

          Mpp::Receipt.success(payload.hash)
        end

        def verify_transaction(payload, request, credential:)
          validate_transaction_payload(payload.signature, request, challenge: credential.challenge)

          raw_tx = payload.signature

          # Simulation payload for the locally co-signed tx, if we sponsor it.
          simulate_payload = nil

          if request.method_details.fee_payer
            payer = fee_payer
            raise Mpp::VerificationError, "No fee payer configured" unless payer

            if local_fee_payer?(payer)
              raw_tx, simulate_payload = cosign_as_fee_payer(raw_tx, request.currency, request: request, challenge: credential.challenge)
            else
              raw_tx = payer.cosign(raw_tx)
            end
          end

          rpc_url = get_rpc_url
          reserved_tx_hash = T.let(nil, T.nilable(String))
          store_key = T.let(nil, T.nilable(String))
          if @store
            reserved_tx_hash = raw_transaction_hash(raw_tx)
            store_key = "mpp:charge:#{reserved_tx_hash.downcase}"
            unless @store.put_if_absent(store_key, TRANSACTION_PENDING)
              raise Mpp::VerificationError, "Transaction hash already used" unless @store.get(store_key) == TRANSACTION_PENDING

              receipt_data = fetch_transaction_receipt(rpc_url, reserved_tx_hash)
              verify_transaction_receipt!(receipt_data, request, credential: credential)
              @store.put(store_key, TRANSACTION_VERIFIED)
              return Mpp::Receipt.success(reserved_tx_hash)
            end
          end

          # We pay the gas, so simulate the co-signed tx first and bail if it
          # would revert. Fails closed: no simulation, no broadcast.
          begin
            simulate_before_broadcast(simulate_payload, rpc_url) if simulate_payload
          rescue
            @store.delete(store_key) if @store && store_key
            raise
          end

          tx_hash = T.let(nil, T.nilable(String))
          begin
            tx_hash = Rpc.call(rpc_url, "eth_sendRawTransaction", [raw_tx])
          rescue => e
            if reserved_tx_hash && store_key && transaction_submission_may_have_succeeded?(e)
              receipt_data = fetch_transaction_receipt(rpc_url, reserved_tx_hash)
              verify_transaction_receipt!(receipt_data, request, credential: credential)
              @store&.put(store_key, TRANSACTION_VERIFIED)
              return Mpp::Receipt.success(reserved_tx_hash)
            end

            @store.delete(store_key) if @store && store_key
            raise Mpp::VerificationError, "Transaction submission failed: #{e.message}"
          end

          unless tx_hash
            @store.delete(store_key) if @store && store_key
            raise Mpp::VerificationError, "No transaction hash returned"
          end

          if reserved_tx_hash && tx_hash.downcase != reserved_tx_hash.downcase
            @store.delete(store_key) if @store && store_key
            raise Mpp::VerificationError, "Returned transaction hash does not match submitted transaction"
          end

          tx_hash = reserved_tx_hash || tx_hash
          receipt_data = fetch_transaction_receipt(rpc_url, tx_hash)
          verify_transaction_receipt!(receipt_data, request, credential: credential)
          @store.put(store_key, TRANSACTION_VERIFIED) if @store && store_key

          Mpp::Receipt.success(tx_hash)
        end

        def transaction_submission_may_have_succeeded?(error)
          message = "#{error.class}: #{error.message}".downcase

          message.include?("timeout") ||
            message.include?("timed out") ||
            message.include?("already known") ||
            message.include?("already imported") ||
            message.include?("known transaction") ||
            message.include?("transaction already exists")
        end

        def fetch_transaction_receipt(rpc_url, tx_hash)
          receipt_data = T.let(nil, T.untyped)
          MAX_RECEIPT_RETRY_ATTEMPTS.times do |attempt|
            receipt_data = Rpc.call(rpc_url, "eth_getTransactionReceipt", [tx_hash])
            break if receipt_data

            sleep(RECEIPT_RETRY_DELAY_SECONDS) if attempt < MAX_RECEIPT_RETRY_ATTEMPTS - 1
          end

          unless receipt_data
            raise Mpp::TransactionPendingError,
              "Transaction receipt pending; retry verification later"
          end

          receipt_data
        end

        def verify_transaction_receipt!(receipt_data, request, credential:)
          raise Mpp::VerificationError, "Transaction reverted" unless receipt_data["status"] == "0x1"
          matched_logs = match_transfer_logs(receipt_data, request, expected_sender: receipt_data["from"])
          unless matched_logs.any?
            raise Mpp::VerificationError,
              "Transaction must contain a Transfer log matching request parameters"
          end
          assert_challenge_bound_memo(matched_logs, credential.challenge) unless request.method_details.memo
        end

        def verify_transfer_logs(receipt, request, expected_sender: nil)
          match_transfer_logs(receipt, request, expected_sender: expected_sender).any?
        end

        def match_transfer_logs(receipt, request, expected_sender: nil, source: nil, validate_sender: nil)
          expected_memo = request.method_details.memo
          matched_logs = []

          (receipt["logs"] || []).each do |log|
            next unless log["address"]&.downcase == request.currency.downcase

            topics = log["topics"] || []
            next if topics.length < 3

            from_address = "0x#{topics[1][-40..]}"
            to_address = "0x#{topics[2][-40..]}"

            next unless to_address.downcase == request.recipient.downcase

            matched =
              if expected_memo
                next unless topics[0] == TRANSFER_WITH_MEMO_TOPIC
                next if topics.length < 4

                data = log.fetch("data", "0x")
                next if data.length < 66

                amount = data[2, 64].to_i(16)
                memo = topics[3]
                memo_clean = expected_memo.downcase
                memo_clean = "0x#{memo_clean}" unless memo_clean.start_with?("0x")
                next unless amount == Integer(request.amount) && memo.downcase == memo_clean

                {kind: :memo, memo: memo}
              else
                case topics[0]
                when TRANSFER_WITH_MEMO_TOPIC
                  next if topics.length < 4

                  data = log.fetch("data", "0x")
                  next if data.length < 66

                  amount = data[2, 64].to_i(16)
                  next unless amount == Integer(request.amount)

                  {kind: :memo, memo: topics[3]}
                when TRANSFER_TOPIC
                  data = log.fetch("data", "0x")
                  next if data.length < 66

                  amount = data.delete_prefix("0x").to_i(16)
                  next unless amount == Integer(request.amount)

                  {kind: :transfer}
                end
              end

            next unless matched

            # On a sender mismatch, validate_sender may authorize the log.
            if expected_sender && from_address.downcase != expected_sender.downcase
              next unless validate_sender&.call(
                expected_sender: expected_sender,
                sender: from_address,
                source: source
              )
            end

            matched_logs << matched
          end

          matched_logs.sort_by { |log| (log[:kind] == :memo) ? 0 : 1 }
        end

        def assert_challenge_bound_memo(matched_logs, challenge)
          bound = matched_logs.any? do |log|
            log[:kind] == :memo &&
              Attribution.verify_server(log[:memo], challenge.realm) &&
              Attribution.verify_challenge_binding(log[:memo], challenge.id)
          end

          return if bound

          raise Mpp::VerificationError, "Payment verification failed: memo is not bound to this challenge"
        end

        def validate_transaction_payload(signature, request, challenge: nil)
          # Best-effort pre-broadcast check
          begin
            require "rlp"
          rescue LoadError
            return
          end

          begin
            tx_bytes = [signature.delete_prefix("0x")].pack("H*")
          rescue ArgumentError
            return
          end

          return if tx_bytes.empty? || ![0x76, 0x78].include?(tx_bytes.getbyte(0))

          begin
            decoded = RLP.decode(tx_bytes[1..])
          rescue
            return
          end

          return unless decoded.is_a?(Array) && decoded.length >= 5

          chain_id = int_value(decoded[0])
          unless chain_id == Integer(request.method_details.chain_id)
            raise Mpp::VerificationError, "Invalid transaction: chain ID does not match request"
          end

          calls_data = decoded[4] || []
          raise Mpp::VerificationError, "Transaction contains no calls" if calls_data.empty?

          found = calls_data.any? do |call_item|
            next unless call_item.is_a?(Array) && call_item.length >= 3

            call_to_bytes = call_item[0]
            call_data_bytes = call_item[2]
            next unless call_to_bytes && call_data_bytes

            to_hex = call_to_bytes.is_a?(String) ? call_to_bytes.unpack1("H*") : call_to_bytes.to_s
            next unless "0x#{to_hex}".downcase == request.currency.downcase

            data_hex = call_data_bytes.is_a?(String) ? call_data_bytes.unpack1("H*") : call_data_bytes.to_s
            match_transfer_calldata(data_hex, request, challenge: challenge)
          end

          raise Mpp::VerificationError, "Invalid transaction: no matching payment call found" unless found
        end

        def raw_transaction_hash(raw_tx)
          Kernel.require "eth"

          hex = raw_tx.delete_prefix("0x")
          unless hex.match?(/\A[0-9a-fA-F]+\z/) && hex.length.even?
            raise Mpp::VerificationError, "Invalid transaction signature"
          end

          "0x#{Eth::Util.keccak256([hex].pack("H*")).unpack1("H*")}"
        rescue LoadError
          raise Mpp::VerificationError,
            "eth gem is required to compute transaction hash for transaction replay protection"
        end

        def match_transfer_calldata(call_data_hex, request, challenge: nil)
          return false if call_data_hex.length < 136

          selector = call_data_hex[0, 8].downcase
          expected_memo = request.method_details.memo

          if expected_memo
            return false unless selector == TRANSFER_WITH_MEMO_SELECTOR
          elsif selector != TRANSFER_WITH_MEMO_SELECTOR
            return false
          end

          decoded_to = "0x#{call_data_hex[32, 40]}"
          decoded_amount = call_data_hex[72, 64].to_i(16)

          return false unless decoded_to.downcase == request.recipient.downcase
          return false unless decoded_amount == Integer(request.amount)
          return false if call_data_hex.length < 200

          if expected_memo
            decoded_memo = "0x#{call_data_hex[136, 64]}"
            memo_clean = expected_memo.downcase
            memo_clean = "0x#{memo_clean}" unless memo_clean.start_with?("0x")
            return false unless decoded_memo.downcase == memo_clean
          else
            return false unless challenge

            decoded_memo = "0x#{call_data_hex[136, 64]}"
            return false unless Attribution.verify_server(decoded_memo, challenge.realm)
            return false unless Attribution.verify_challenge_binding(decoded_memo, challenge.id)
          end

          true
        end

        def verify_proof(payload, request, credential:)
          raise Mpp::VerificationError, "Proof credentials are only valid for zero-amount challenges" unless Integer(request.amount).zero?
          raise Mpp::VerificationError, "Proof credential must include a source" unless credential.source

          resolved_chain_id = request.method_details.chain_id
          source = Proof.parse_source(credential.source)
          raise Mpp::VerificationError, "Proof credential source is invalid" unless source
          raise Mpp::VerificationError, "Proof credential source chain mismatch" unless source[:chain_id] == resolved_chain_id

          valid = Proof.verify(
            address: source[:address],
            chain_id: resolved_chain_id,
            challenge_id: credential.challenge.id,
            realm: credential.challenge.realm,
            signature: payload.signature
          )
          raise Mpp::VerificationError, "Proof signature does not match source" unless valid

          if @store
            store_key = "mpp:proof:#{credential.challenge.id}"
            raise Mpp::VerificationError, "Proof credential has already been used" unless @store.put_if_absent(store_key, true)
          end

          Mpp::Receipt.success(credential.challenge.id)
        end

        def local_fee_payer?(payer)
          !FeePayerClient.hosted_config?(payer)
        end

        def cosign_as_fee_payer(raw_tx, fee_token, request: nil, challenge: nil)
          require "eth"
          require "rlp"

          raise Mpp::VerificationError, "No fee payer account configured" unless fee_payer

          # Decode the 0x78 fee payer envelope
          begin
            all_bytes = [raw_tx.delete_prefix("0x")].pack("H*")
            decoded, sender_addr_bytes, sender_sig, key_auth = FeePayer.decode(all_bytes)
          rescue => e
            raise Mpp::VerificationError, "Failed to deserialize client transaction: #{e.message}"
          end

          # Validate fee-payer invariants
          fee_token_field = decoded[10]
          if fee_token_field.is_a?(String) && !fee_token_field.empty?
            raise Mpp::VerificationError, "Fee payer transaction must not include fee_token (server sets it)"
          end

          # Reject authorizations we can't replay in tempo_simulateV1, which
          # would let preflight validate a different tx than we broadcast.
          tempo_authorization_list = decoded[12]
          if tempo_authorization_list.is_a?(Array) && !tempo_authorization_list.empty?
            raise Mpp::VerificationError,
              "Fee payer envelope must not include tempo_authorization_list (cannot be safely pre-simulated)"
          end
          unless key_auth.nil?
            raise Mpp::VerificationError,
              "Fee payer envelope must not include key_authorization (cannot be safely pre-simulated)"
          end

          nonce_key = int_value(decoded[6])
          unless nonce_key == (1 << 256) - 1
            raise Mpp::VerificationError, "Fee payer envelope must use expiring nonce key (U256::MAX)"
          end

          valid_before_raw = decoded[8]
          if !valid_before_raw.is_a?(String) || valid_before_raw.empty?
            raise Mpp::VerificationError, "Fee payer envelope must include valid_before"
          end
          valid_before = int_value(valid_before_raw)
          if valid_before <= Time.now.to_i
            raise Mpp::VerificationError,
              "Fee payer envelope expired: valid_before (#{valid_before}) is not in the future"
          end

          chain_id = int_value(decoded[0])
          if request && chain_id != Integer(request.method_details.chain_id)
            raise Mpp::VerificationError, "Invalid transaction: chain ID does not match request"
          end
          max_priority_fee_per_gas = int_value(decoded[1])
          max_fee_per_gas = int_value(decoded[2])
          gas_limit = int_value(decoded[3])
          access_list = decoded[5] || Transaction::EMPTY_LIST
          policy = FeePayerPolicy.for_chain_id(chain_id)

          if gas_limit > policy.max_gas
            raise Mpp::VerificationError, "Invalid transaction: gas limit exceeds sponsor policy"
          end
          if max_fee_per_gas > policy.max_fee_per_gas
            raise Mpp::VerificationError, "Invalid transaction: max fee per gas exceeds sponsor policy"
          end
          if max_priority_fee_per_gas > max_fee_per_gas
            raise Mpp::VerificationError,
              "Invalid transaction: max priority fee per gas exceeds max fee per gas"
          end
          if max_priority_fee_per_gas > policy.max_priority_fee_per_gas
            raise Mpp::VerificationError,
              "Invalid transaction: max priority fee per gas exceeds sponsor policy"
          end
          if gas_limit * max_fee_per_gas > policy.max_total_fee
            raise Mpp::VerificationError, "Invalid transaction: total fee budget exceeds sponsor policy"
          end
          if valid_before > Time.now.to_i + policy.max_validity_window_seconds
            raise Mpp::VerificationError, "Invalid transaction: validity window exceeds sponsor policy"
          end
          unless access_list.empty?
            raise Mpp::VerificationError, "Invalid transaction: access list is not allowed"
          end

          # Build calls from decoded RLP
          calls_data = decoded[4] || []
          calls = calls_data.map do |c|
            Transaction::Call.new(
              to: "0x#{c[0].unpack1("H*")}",
              value: int_value(c[1]),
              data: "0x#{c[2].unpack1("H*")}"
            )
          end

          validate_fee_payer_calls(calls, request, challenge: challenge) if request

          # Reconstruct transaction for sender signature recovery
          tx_for_recovery = Transaction::SignedTransaction.new(
            chain_id: chain_id,
            max_priority_fee_per_gas: max_priority_fee_per_gas,
            max_fee_per_gas: max_fee_per_gas,
            gas_limit: gas_limit,
            calls: calls,
            access_list: Transaction::EMPTY_LIST,
            nonce_key: int_value(decoded[6]),
            nonce: int_value(decoded[7]),
            valid_before: int_value(decoded[8]),
            valid_after: (decoded[9].is_a?(String) && !decoded[9].empty?) ? int_value(decoded[9]) : nil,
            fee_token: nil,
            sender_signature: sender_sig,
            fee_payer_signature: Transaction::EMPTY_SIGNATURE,
            sender_address: "0x#{sender_addr_bytes.unpack1("H*")}",
            tempo_authorization_list: decoded[12] || Transaction::EMPTY_LIST,
            key_authorization: key_auth
          )

          # Verify sender signature
          sender_hash = tx_for_recovery.signature_hash
          recovered = Eth::Signature.recover(sender_hash, "0x#{sender_sig.unpack1("H*")}")
          recovered_addr = Eth::Util.public_key_to_address(recovered).to_s
          envelope_addr = "0x#{sender_addr_bytes.unpack1("H*")}"

          unless recovered_addr.downcase == envelope_addr.downcase
            raise Mpp::VerificationError, "Sender address does not match recovered signer"
          end

          # Build the final transaction with fee_token set
          resolved_fee_token = fee_token || request&.currency
          raise Mpp::VerificationError, "No fee token available" unless resolved_fee_token

          allowed_fee_tokens = fee_payer_allowed_fee_tokens ||
            [Defaults.default_currency_for_chain(chain_id).downcase]
          unless allowed_fee_tokens.map(&:downcase).include?(resolved_fee_token.downcase)
            raise Mpp::VerificationError,
              "Fee token #{resolved_fee_token} is not allowed by fee payer policy"
          end

          tx_to_sign = tx_for_recovery.with(fee_token: resolved_fee_token)

          # Fee payer signs the 0x78 payload, which identifies the recovered sender.
          fee_payer_hash = tx_to_sign.fee_payer_signature_hash
          fee_payer_sig = fee_payer.sign_hash(fee_payer_hash)

          signed = tx_to_sign.with(fee_payer_signature: fee_payer_sig)
          raw_tx = "0x#{signed.encoded_2718.unpack1("H*")}"

          [raw_tx, build_simulate_payload(tx_to_sign, recovered_addr, fee_payer_sig)]
        end

        # Build a `tempo_simulateV1` payload for the co-signed `0x76` tx.
        #
        # Carries the recovered sender as `from` (the node needs it to model the
        # sender) plus the sponsor fields (`feeToken`, `feePayerSignature`) so the
        # node simulates the same tx we are about to broadcast.
        def build_simulate_payload(tx, sender, fee_payer_sig)
          tx_request = {
            "from" => sender,
            "type" => "0x76",
            "chainId" => to_hex(tx.chain_id),
            "nonce" => to_hex(tx.nonce),
            "nonceKey" => to_hex(tx.nonce_key),
            "gas" => to_hex(tx.gas_limit),
            "maxFeePerGas" => to_hex(tx.max_fee_per_gas),
            "maxPriorityFeePerGas" => to_hex(tx.max_priority_fee_per_gas),
            "feeToken" => tx.fee_token,
            "feePayerSignature" => signature_object(fee_payer_sig)
          }

          # The node forces `to = CREATE` when a request has no top-level `to`,
          # appending a phantom CREATE call that trips Tempo's batch rules. Carry
          # the final call via the top-level `to`/`value`/`input` shorthand (the
          # builder appends it last, preserving order); keep earlier calls in `calls`.
          raise Mpp::VerificationError, "Cannot simulate transaction with no calls" if tx.calls.empty?
          *head_calls, last_call = tx.calls
          unless head_calls.empty?
            tx_request["calls"] = head_calls.map do |c|
              {"to" => c.to, "value" => to_hex(c.value), "input" => c.data}
            end
          end
          tx_request["to"] = last_call.to
          tx_request["value"] = to_hex(last_call.value)
          tx_request["input"] = last_call.data

          tx_request["validBefore"] = to_hex(tx.valid_before) if tx.valid_before
          tx_request["validAfter"] = to_hex(tx.valid_after) if tx.valid_after
          access_list = encode_access_list(tx.access_list)
          tx_request["accessList"] = access_list unless access_list.empty?

          {
            "blockStateCalls" => [{"calls" => [tx_request]}],
            # We only care about execution outcome, not mempool admission.
            "validation" => false,
            "traceTransfers" => false,
            "returnFullTransactions" => false
          }
        end

        # Simulate the co-signed tx and raise if it would revert. Fails closed:
        # an RPC error is treated as a failed check, not a pass.
        def simulate_before_broadcast(simulate_payload, rpc_url)
          response =
            begin
              Rpc.call(rpc_url, "tempo_simulateV1", [simulate_payload])
            rescue => e
              raise Mpp::VerificationError, "Pre-broadcast simulation failed: #{e.message}"
            end

          call = response&.dig("blocks", 0, "calls", 0)
          raise Mpp::VerificationError, "Pre-broadcast simulation returned no call results" unless call

          status = call["status"]
          succeeded = status == "0x1" || status == 1 || status == true
          return if succeeded

          detail = call.dig("error", "message") || "no revert reason returned"
          raise Mpp::VerificationError,
            "Sponsored transaction would revert in pre-broadcast simulation: #{detail}"
        end

        # Encode an integer as a 0x-prefixed hex quantity.
        def to_hex(value)
          "0x#{Integer(value).to_s(16)}"
        end

        # Convert the RLP-decoded access list ([addr_bytes, [key_bytes, ...]])
        # into the JSON shape the node expects.
        def encode_access_list(access_list)
          (access_list || []).map do |address, keys|
            {
              "address" => "0x#{address.unpack1("H*")}",
              "storageKeys" => (keys || []).map { |k| "0x#{k.unpack1("H*")}" }
            }
          end
        end

        # Split a 65-byte (r||s||v) signature into the {r, s, yParity} object the
        # node expects for `feePayerSignature`.
        def signature_object(sig)
          bytes = sig.b
          v = bytes.getbyte(64)
          parity = (v >= 27) ? v - 27 : v
          {
            "r" => "0x#{bytes[0, 32].unpack1("H*")}",
            "s" => "0x#{bytes[32, 32].unpack1("H*")}",
            "yParity" => to_hex(parity)
          }
        end

        # Expected calldata length for transferWithMemo(address,uint256,bytes32):
        # 4 (selector) + 32 (address) + 32 (amount) + 32 (memo) = 100 bytes = 200 hex chars
        MAX_TRANSFER_CALLDATA_HEX_LENGTH = 200

        def validate_fee_payer_calls(calls, request, challenge: nil)
          if calls.length != 1
            raise Mpp::VerificationError, "Invalid transaction: contains unauthorized extra calls"
          end

          call = calls.first
          if call.value && Integer(call.value) != 0
            raise Mpp::VerificationError, "Invalid transaction: no matching payment call found"
          end
          unless call.to.downcase == request.currency.downcase
            raise Mpp::VerificationError, "Invalid transaction: no matching payment call found"
          end

          call_data_hex = call.data.delete_prefix("0x")
          if call_data_hex.length > MAX_TRANSFER_CALLDATA_HEX_LENGTH
            raise Mpp::VerificationError,
              "Invalid transaction: calldata contains trailing padding (#{call_data_hex.length / 2} bytes, expected #{MAX_TRANSFER_CALLDATA_HEX_LENGTH / 2})"
          end

          unless match_transfer_calldata(call_data_hex, request, challenge: challenge)
            raise Mpp::VerificationError, "Invalid transaction: no matching payment call found"
          end
        end

        def int_value(value)
          if value.is_a?(String) && !value.empty?
            value.unpack1("H*").to_i(16)
          elsif value.is_a?(Integer)
            value
          else
            0
          end
        end
      end
    end
  end
end
