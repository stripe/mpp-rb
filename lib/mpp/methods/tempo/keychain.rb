# typed: true
# frozen_string_literal: true

module Mpp
  module Methods
    module Tempo
      module Keychain
        SIGNATURE_TYPE = 0x03
        SIGNATURE_LENGTH = 86

        module_function

        # Build a Keychain signature for a message hash.
        #
        # Format: 0x03 || root_account (20 bytes) || inner_sig (65 bytes)
        # Total: 86 bytes
        def build_signature(msg_hash:, access_key:, root_account:)
          inner_sig = access_key.sign_hash(msg_hash)
          root_bytes = [root_account.delete_prefix("0x")].pack("H*")

          keychain_sig = [SIGNATURE_TYPE].pack("C") + root_bytes + inner_sig
          unless keychain_sig.bytesize == SIGNATURE_LENGTH
            Kernel.raise "Invalid keychain signature length: #{keychain_sig.bytesize}"
          end

          keychain_sig
        end
      end
    end
  end
end
