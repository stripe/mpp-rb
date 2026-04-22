# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Tempo
      module FeePayer
        TYPE_ID = 0x78

        module_function

        # Encode a sender-signed transaction as a 0x78 fee payer envelope.
        # Requires the `rlp` gem.
        #
        # Wire format: 0x78 || RLP([fields...])
        def encode(signed_tx)
          Kernel.require "rlp"

          sender_sig = signed_tx.sender_signature
          sig_bytes = sender_sig.respond_to?(:to_bytes) ? sender_sig.to_bytes : sender_sig.to_s.b
          sender_addr = signed_tx.sender_address.to_s.b

          fields = [
            signed_tx.chain_id,
            signed_tx.max_priority_fee_per_gas,
            signed_tx.max_fee_per_gas,
            signed_tx.gas_limit,
            signed_tx.calls.map(&:as_rlp_list),
            signed_tx.access_list.map(&:as_rlp_list),
            signed_tx.nonce_key,
            signed_tx.nonce,
            encode_optional_uint(signed_tx.valid_before),
            encode_optional_uint(signed_tx.valid_after),
            signed_tx.fee_token ? signed_tx.fee_token.to_s.b : "".b,
            sender_addr,
            signed_tx.tempo_authorization_list.to_a
          ]

          fields << RLP.decode(signed_tx.key_authorization) if signed_tx.key_authorization
          fields << sig_bytes

          [TYPE_ID].pack("C") + RLP.include(fields)
        end

        # Decode a 0x78 fee payer envelope.
        #
        # Returns [decoded_fields, sender_address_bytes, sender_signature_bytes, key_authorization_or_nil]
        def decode(data)
          Kernel.require "rlp"

          Kernel.raise ArgumentError, "Not a fee payer envelope (expected 0x78 prefix)" unless data.getbyte(0) == TYPE_ID

          decoded = RLP.decode(data[1..])
          Kernel.raise ArgumentError, "Malformed fee payer envelope" unless decoded.is_a?(Array) && decoded.length >= 14

          sender_address = decoded[11]
          sender_signature = decoded[-1]

          # 15 fields = key_authorization present (index 13), signature at 14
          # 14 fields = no key_authorization, signature at 13
          key_authorization = (RLP.include(decoded[13]) if decoded.length == 15)

          [decoded, sender_address.to_s.b, sender_signature.to_s.b, key_authorization]
        end

        def encode_optional_uint(value)
          return "".b unless value

          value.is_a?(Integer) ? value : value.to_i
        end
      end
    end
  end
end
