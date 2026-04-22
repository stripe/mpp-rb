# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Tempo
      module Transaction
        TYPE_ID = 0x76
        EMPTY_SIGNATURE = "\x00".b
        EMPTY_LIST = [].freeze

        Call = Data.define(:to, :value, :data) do
          def as_rlp_list
            [pack_address(to), encode_uint(value), pack_bytes(data)]
          end

          private

          def pack_address(value)
            [value.delete_prefix("0x")].pack("H*")
          end

          def pack_bytes(value)
            [value.delete_prefix("0x")].pack("H*")
          end

          def encode_uint(value)
            Integer(value)
          end
        end

        SignedTransaction = Data.define(
          :chain_id, :max_priority_fee_per_gas, :max_fee_per_gas, :gas_limit,
          :calls, :access_list, :nonce_key, :nonce, :valid_before, :valid_after,
          :fee_token, :sender_signature, :fee_payer_signature, :sender_address,
          :tempo_authorization_list, :key_authorization
        ) do
          def encoded_2718
            require_rlp!

            [TYPE_ID].pack("C") + RLP.encode(rlp_fields)
          end

          def signature_hash
            require_eth!
            require_rlp!

            Eth::Util.keccak256([TYPE_ID].pack("C") + RLP.encode(unsigned_rlp_fields))
          end

          # Hash for fee payer to sign — includes sender_signature in the RLP.
          def fee_payer_signature_hash
            require_eth!
            require_rlp!

            fields = unsigned_rlp_fields
            fields.insert(11, sender_signature)
            Eth::Util.keccak256([TYPE_ID].pack("C") + RLP.encode(fields))
          end

          private

          def rlp_fields
            fields = unsigned_rlp_fields
            fields.insert(11, sender_signature)
            fields.insert(12, fee_payer_signature || EMPTY_SIGNATURE)
            fields
          end

          def unsigned_rlp_fields
            fields = [
              chain_id,
              max_priority_fee_per_gas,
              max_fee_per_gas,
              gas_limit,
              calls.map(&:as_rlp_list),
              access_list || EMPTY_LIST,
              nonce_key,
              nonce,
              encode_optional_uint(valid_before),
              encode_optional_uint(valid_after),
              fee_token ? pack_hex(fee_token) : "".b,
              tempo_authorization_list || EMPTY_LIST
            ]
            fields << key_authorization if key_authorization
            fields
          end

          def pack_hex(value)
            [value.delete_prefix("0x")].pack("H*")
          end

          def encode_optional_uint(value)
            return "".b if value.nil?

            Integer(value)
          end

          def require_eth!
            Kernel.require "eth"
          rescue LoadError
            raise LoadError, "eth gem is required for Tempo transaction signing. Install with: gem install eth"
          end

          def require_rlp!
            Kernel.require "rlp"
          rescue LoadError
            raise LoadError, "rlp gem is required for Tempo transaction encoding. Install with: gem install rlp"
          end
        end

        module_function

        def build_signed_transfer(account:, chain_id:, gas_limit:, gas_price:, nonce:, nonce_key:,
          currency:, transfer_data:, valid_before: nil, awaiting_fee_payer: false)
          tx = SignedTransaction.new(
            chain_id: chain_id,
            max_priority_fee_per_gas: gas_price,
            max_fee_per_gas: gas_price,
            gas_limit: gas_limit,
            calls: [Call.new(to: currency, value: 0, data: transfer_data)],
            access_list: EMPTY_LIST,
            nonce_key: nonce_key,
            nonce: nonce,
            valid_before: valid_before,
            valid_after: nil,
            fee_token: awaiting_fee_payer ? nil : currency,
            sender_signature: nil,
            fee_payer_signature: EMPTY_SIGNATURE,
            sender_address: account.address,
            tempo_authorization_list: EMPTY_LIST,
            key_authorization: nil
          )

          signature = account.sign_hash(tx.signature_hash)
          signed = tx.with(sender_signature: signature)
          raw = awaiting_fee_payer ? FeePayer.encode(signed) : signed.encoded_2718

          ["0x#{raw.unpack1("H*")}", chain_id]
        end
      end
    end
  end
end
