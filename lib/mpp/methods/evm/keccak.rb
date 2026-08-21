# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Evm
      # Ethereum Keccak-256 (not NIST SHA3-256). EIP-55 checksums use this so
      # x402 `asset` / `payTo` can be emitted without the optional `eth` gem.
      module Keccak
        module_function

        RC = [
          0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
          0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
          0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
          0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
          0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
          0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
        ].freeze

        ROT = [
          0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8, 18, 2, 61, 56, 14
        ].freeze

        MASK = 0xFFFFFFFFFFFFFFFF
        RATE = 136

        def digest(data)
          padded = data.b.bytes
          pad_len = RATE - (padded.length % RATE)
          pad_len = RATE if pad_len.zero?
          pad = Array.new(pad_len, 0)
          pad[0] = 0x01
          pad[-1] |= 0x80
          padded.concat(pad)

          state = Array.new(25, 0)
          padded.each_slice(RATE) do |block|
            absorb_block(state, block)
            keccak_f(state)
          end

          out = +"".b
          4.times do |lane|
            8.times { |byte| out << ((state[lane] >> (8 * byte)) & 0xff) }
          end
          out
        end

        def hexdigest(data)
          digest(data).unpack1("H*")
        end

        def absorb_block(state, block)
          block.each_with_index do |byte, index|
            state[index / 8] = (state[index / 8] ^ (byte << (8 * (index % 8)))) & MASK
          end
        end
        private_class_method :absorb_block

        def keccak_f(lanes)
          24.times do |round|
            column = Array.new(5) { |x| lanes[x] ^ lanes[x + 5] ^ lanes[x + 10] ^ lanes[x + 15] ^ lanes[x + 20] }
            d = Array.new(5) { |x| column[(x - 1) % 5] ^ rotl(column[(x + 1) % 5], 1) }
            25.times { |index| lanes[index] = (lanes[index] ^ d[index % 5]) & MASK }

            mixed = Array.new(25, 0)
            25.times do |index|
              x = index % 5
              y = index / 5
              mixed[y + (5 * ((2 * x + 3 * y) % 5))] = rotl(lanes[index], ROT[index])
            end

            25.times do |index|
              x = index % 5
              lanes[index] = (mixed[index] ^ ((~mixed[index - x + ((x + 1) % 5)]) & mixed[index - x + ((x + 2) % 5)])) & MASK
            end

            lanes[0] = (lanes[0] ^ RC[round]) & MASK
          end
        end
        private_class_method :keccak_f

        def rotl(value, bits)
          bits %= 64
          ((value << bits) | (value >> (64 - bits))) & MASK
        end
        private_class_method :rotl
      end
    end
  end
end
