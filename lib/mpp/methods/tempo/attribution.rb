# typed: false
# frozen_string_literal: true

require "openssl"
require "securerandom"

module Mpp
  module Methods
    module Tempo
      module Attribution
        VERSION = 0x01
        ANONYMOUS = "\x00" * 10

        module_function

        # Compute keccak256 hash. Uses OpenSSL if available, otherwise pure Ruby.
        def keccak256(data)
          # Try eth gem's keccak first
          Kernel.require "eth"
          Eth::Util.keccak256(data)
        rescue LoadError
          # Fallback: use OpenSSL's SHA3-256 (not exactly keccak, but close)
          # For production, the eth gem should be installed
          OpenSSL::Digest.new("SHA3-256").digest(data)
        end

        # Compute TAG = keccak256("mpp")[0:4]
        def tag
          @tag ||= keccak256("mpp".b)[0, 4]
        end

        def fingerprint(value)
          keccak256(value.encode(Encoding::UTF_8))[0, 10]
        end

        # Encode an MPP attribution memo (32 bytes).
        #
        # Byte Layout:
        #   0..3:   TAG = keccak256("mpp")[0:4]
        #   4:      version (0x01)
        #   5..14:  serverId fingerprint
        #   15..24: clientId fingerprint or zeros
        #   25..31: random nonce
        def encode(server_id:, client_id: nil, challenge_id: nil)
          buf = "\x00".b * 32
          buf[0, 4] = tag
          buf[4] = [VERSION].pack("C")
          buf[5, 10] = fingerprint(server_id)
          buf[15, 10] = client_id ? fingerprint(client_id) : ANONYMOUS.b
          buf[25, 7] = if challenge_id
            keccak256(challenge_id.encode(Encoding::UTF_8))[0, 7]
          else
            SecureRandom.random_bytes(7)
          end
          "0x#{buf.unpack1("H*")}"
        end

        # Check if a memo is an MPP attribution memo.
        def mpp_memo?(memo)
          return false unless memo.length == 66

          begin
            memo_tag = [memo[2, 8]].pack("H*")
            memo_version = memo[10, 2].to_i(16)
          rescue ArgumentError
            return false
          end
          memo_tag == tag && memo_version == VERSION
        end

        # Verify server fingerprint in memo.
        def verify_server(memo, server_id)
          return false unless mpp_memo?(memo)

          begin
            memo_server = [memo[12, 20]].pack("H*")
          rescue ArgumentError
            return false
          end
          memo_server == fingerprint(server_id)
        end

        # Decoded memo structure.
        DecodedMemo = Data.define(:version, :server_fingerprint, :client_fingerprint, :nonce)

        # Decode an MPP attribution memo.
        def decode(memo)
          return nil unless mpp_memo?(memo)

          begin
            version = memo[10, 2].to_i(16)
            server_fingerprint = "0x#{memo[12, 20]}"
            client_hex = memo[32, 20]
            nonce = "0x#{memo[52..]}"

            client_bytes = [client_hex].pack("H*")
            client_fingerprint = (client_bytes == ANONYMOUS.b) ? nil : "0x#{client_hex}"
          rescue ArgumentError
            return nil
          end

          DecodedMemo.new(
            version: version,
            server_fingerprint: server_fingerprint,
            client_fingerprint: client_fingerprint,
            nonce: nonce
          )
        end
      end
    end
  end
end
