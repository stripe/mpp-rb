# typed: false
# frozen_string_literal: true

require_relative "keccak"

module Mpp
  module Methods
    module Evm
      # EIP-712 TransferWithAuthorization hashing and recovery.
      module Authorization
        DOMAIN_TYPE_HASH = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        TRANSFER_TYPE_HASH = "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"

        module_function

        def keccak256(data)
          Keccak.digest(data)
        end

        def challenge_hash(challenge)
          digest = keccak256("#{challenge.id}#{challenge.realm}")
          "0x#{digest.unpack1("H*")}"
        end

        def checksum_address(address)
          hex = address.to_s.delete_prefix("0x")
          Kernel.raise ArgumentError, "invalid address: #{address}" unless hex.match?(/\A[a-fA-F0-9]{40}\z/)

          hash = Keccak.hexdigest(hex.downcase)
          checksummed = hex.downcase.chars.each_with_index.map { |char, index|
            (char.match?(/[a-f]/) && hash[index].to_i(16) >= 8) ? char.upcase : char
          }.join
          "0x#{checksummed}"
        end

        def signing_hash(authorization:, chain_id:, currency:, from:, to:, value:, valid_after:, valid_before:, nonce:)
          domain = domain_separator(
            name: authorization["name"] || authorization[:name],
            version: authorization["version"] || authorization[:version],
            chain_id: chain_id,
            verifying_contract: currency
          )
          struct = struct_hash(
            from: from,
            to: to,
            value: value,
            valid_after: valid_after,
            valid_before: valid_before,
            nonce: nonce
          )
          keccak256("\x19\x01".b + domain + struct)
        end

        def recover(authorization:, chain_id:, currency:, payload:)
          hash = signing_hash(
            authorization: authorization,
            chain_id: chain_id,
            currency: currency,
            from: payload["from"],
            to: payload["to"],
            value: payload["value"],
            valid_after: payload["validAfter"],
            valid_before: payload["validBefore"],
            nonce: payload["nonce"]
          )
          recover_address(hash, payload["signature"])
        end

        def domain_separator(name:, version:, chain_id:, verifying_contract:)
          keccak256(
            abi_encode(
              keccak256(DOMAIN_TYPE_HASH),
              keccak256(name),
              keccak256(version),
              uint256(chain_id),
              address_word(verifying_contract)
            )
          )
        end

        def struct_hash(from:, to:, value:, valid_after:, valid_before:, nonce:)
          keccak256(
            abi_encode(
              keccak256(TRANSFER_TYPE_HASH),
              address_word(from),
              address_word(to),
              uint256(value),
              uint256(valid_after),
              uint256(valid_before),
              bytes32_word(nonce)
            )
          )
        end

        def abi_encode(*values)
          values.join
        end

        def uint256(value)
          value = Integer(value)
          raise ArgumentError, "uint256 out of range" if value.negative? || value >= (1 << 256)

          [value.to_s(16).rjust(64, "0")].pack("H*")
        end

        def address_word(value)
          hex = value.to_s.delete_prefix("0x")
          raise ArgumentError, "invalid address: #{value}" unless hex.match?(/\A[a-fA-F0-9]{40}\z/)

          [hex].pack("H*").rjust(32, "\x00".b)
        end

        def bytes32_word(value)
          hex = value.to_s.delete_prefix("0x")
          raise ArgumentError, "invalid bytes32: #{value}" unless hex.match?(/\A[a-fA-F0-9]{64}\z/)

          [hex].pack("H*")
        end

        def recover_address(hash, signature)
          Kernel.require "eth"

          sig = signature.to_s
          sig = "0x#{sig}" unless sig.start_with?("0x")
          recovered_key = Eth::Signature.recover(hash, sig)
          Eth::Util.public_key_to_address(recovered_key).to_s
        rescue
          nil
        end
      end
    end
  end
end
