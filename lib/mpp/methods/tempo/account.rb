# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Tempo
      # Wrapper around the eth gem for signing.
      # Requires the `eth` gem to be installed.
      class Account
        attr_reader :key

        def initialize(key)
          @key = key
        end

        # Load from hex private key (0x-prefixed).
        def self.from_key(private_key)
          require "eth"
          new(Eth::Key.new(priv: private_key.delete_prefix("0x")))
        end

        # Load from environment variable.
        def self.from_env(var = "TEMPO_PRIVATE_KEY")
          key = ENV.fetch(var, nil)
          raise ArgumentError, "$#{var} not set" unless key && !key.empty?

          from_key(key)
        end

        # Get the account's Ethereum address (checksummed).
        def address
          @key.address.to_s
        end

        # Get the private key as hex string.
        def private_key
          "0x#{@key.private_hex}"
        end

        # Sign a 32-byte hash, return 65-byte signature (r || s || v).
        def sign_hash(msg_hash)
          raise ArgumentError, "msg_hash must be 32 bytes, got #{msg_hash.bytesize}" unless msg_hash.bytesize == 32

          sig = @key.sign(msg_hash)
          # eth gem returns hex signature, parse r, s, v
          sig_hex = sig.delete_prefix("0x")
          [sig_hex].pack("H*")
        end
      end
    end
  end
end
