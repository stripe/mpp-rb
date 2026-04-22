# typed: strict
# frozen_string_literal: true

module Mpp
  module Methods
    module Tempo
      module Defaults
        # Mainnet
        CHAIN_ID = 4217
        RPC_URL = "https://rpc.tempo.xyz"
        PATH_USD = "0x20c0000000000000000000000000000000000000"
        USDC = "0x20C000000000000000000000b9537d11c60E8b50"
        PATH_USD_DECIMALS = 6

        # Testnet (Moderato)
        TESTNET_CHAIN_ID = 42_431
        TESTNET_RPC_URL = "https://rpc.moderato.tempo.xyz"

        # Testnet only - fee payer service sponsors gas on testnet
        DEFAULT_FEE_PAYER_URL = "https://sponsor.moderato.tempo.xyz"

        # Chain ID -> default currency mapping
        DEFAULT_CURRENCIES = T.let({
          CHAIN_ID => USDC,
          TESTNET_CHAIN_ID => PATH_USD
        }.freeze, T::Hash[T.untyped, T.untyped])

        # Chain ID -> default RPC URL mapping
        CHAIN_RPC_URLS = T.let({
          CHAIN_ID => RPC_URL,
          TESTNET_CHAIN_ID => TESTNET_RPC_URL
        }.freeze, T::Hash[T.untyped, T.untyped])

        # Chain ID -> escrow contract address mapping
        ESCROW_CONTRACTS = T.let({
          CHAIN_ID => "0x33b901018174DDabE4841042ab76ba85D4e24f25",
          TESTNET_CHAIN_ID => "0xe1c4d3dce17bc111181ddf716f75bae49e61a336"
        }.freeze, T::Hash[T.untyped, T.untyped])

        extend T::Sig

        module_function

        sig { params(chain_id: Integer).returns(String) }
        def rpc_url_for_chain(chain_id)
          url = CHAIN_RPC_URLS[chain_id]
          return url if url

          Kernel.raise ArgumentError,
            "Unknown chain_id #{chain_id}. Known chains: #{CHAIN_RPC_URLS.keys}. Pass rpc_url explicitly."
        end

        sig { params(chain_id: T.nilable(Integer)).returns(String) }
        def default_currency_for_chain(chain_id)
          return PATH_USD if chain_id.nil?

          DEFAULT_CURRENCIES.fetch(chain_id, PATH_USD)
        end

        sig { params(chain_id: T.nilable(Integer), testnet: T::Boolean).returns(String) }
        def resolve_currency(chain_id: nil, testnet: false)
          id = chain_id || (testnet ? TESTNET_CHAIN_ID : CHAIN_ID)
          DEFAULT_CURRENCIES.fetch(id, PATH_USD)
        end

        sig { params(chain_id: Integer).returns(String) }
        def escrow_contract_for_chain(chain_id)
          addr = ESCROW_CONTRACTS[chain_id]
          return addr if addr

          Kernel.raise ArgumentError,
            "Unknown chain_id #{chain_id}. Known chains: #{ESCROW_CONTRACTS.keys}. Pass escrow_contract explicitly."
        end
      end
    end
  end
end
