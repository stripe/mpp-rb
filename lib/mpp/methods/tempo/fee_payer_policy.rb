# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Tempo
      module FeePayerPolicy
        Policy = Data.define(
          :max_gas,
          :max_fee_per_gas,
          :max_priority_fee_per_gas,
          :max_total_fee,
          :max_validity_window_seconds
        )

        DEFAULT = Policy.new(
          max_gas: 2_000_000,
          max_fee_per_gas: 100_000_000_000,
          max_priority_fee_per_gas: 10_000_000_000,
          max_total_fee: 50_000_000_000_000_000,
          max_validity_window_seconds: 15 * 60
        )

        TESTNET = Policy.new(
          max_gas: DEFAULT.max_gas,
          max_fee_per_gas: DEFAULT.max_fee_per_gas,
          max_priority_fee_per_gas: 50_000_000_000,
          max_total_fee: DEFAULT.max_total_fee,
          max_validity_window_seconds: DEFAULT.max_validity_window_seconds
        )

        module_function

        def for_chain_id(chain_id)
          case chain_id
          when Defaults::TESTNET_CHAIN_ID
            TESTNET
          else
            DEFAULT
          end
        end
      end
    end
  end
end
