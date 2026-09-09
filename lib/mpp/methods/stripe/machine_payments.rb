# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Stripe
      # Configures Stripe-backed MPP methods with static deposit addresses.
      class MachinePayments
        SPT_MINIMUM_MINOR_UNITS = 50

        attr_reader :spt, :tempo, :base

        def initialize(network_id:, livemode:, client:, deposit_addresses: nil, metadata: nil)
          raise ArgumentError, "client must respond to #v1" unless client.respond_to?(:v1)

          addresses = normalize_deposit_addresses(deposit_addresses)
          @spt = SptFactory.new(network_id: network_id, client: client, metadata: metadata)
          @tempo = TempoFactory.new(livemode: livemode, client: client, recipient: addresses[:tempo], metadata: metadata)
          @base = BaseFactory.new(livemode: livemode, client: client, recipient: addresses[:base], metadata: metadata)
        end

        # Tempo is preferred when configured; Base requires an explicit facilitator.
        def default_methods
          methods = [spt.charge]
          methods.unshift(tempo.charge) if tempo.configured?
          methods
        end

        def self.minimum_amount(minimum)
          lambda do |request|
            Integer(request.fetch("amount")) >= minimum
          rescue ArgumentError, TypeError, KeyError
            false
          end
        end

        private

        def normalize_deposit_addresses(deposit_addresses)
          return {} if deposit_addresses.nil?
          raise ArgumentError, "deposit_addresses must be a Hash" unless deposit_addresses.is_a?(Hash)

          deposit_addresses.each_with_object({}) do |(network, address), result|
            unless [:tempo, :base].include?(network)
              raise ArgumentError, "unsupported deposit address network: #{network}"
            end
            unless address.is_a?(String) && address.match?(/\A0x[0-9a-fA-F]{40}\z/)
              raise ArgumentError, "deposit_addresses[:#{network}] must be a 0x-prefixed 40-hex-character address"
            end

            result[network] = address.dup.freeze
          end
        end
      end

      class SptFactory
        def initialize(network_id:, client:, metadata:)
          @network_id = network_id
          @client = client
          @metadata = metadata
        end

        def charge
          method = Mpp::Methods::Stripe::StripeMethod.new(
            secret_key: nil,
            network_id: @network_id,
            payment_methods: ["card", "link"],
            metadata: @metadata,
            can_offer: MachinePayments.minimum_amount(MachinePayments::SPT_MINIMUM_MINOR_UNITS)
          )
          method.intents = {"charge" => Mpp::Methods::Stripe::ChargeIntent.new(secret_key: nil, client: @client)}
          PaymentIntentMethod.new(method: method)
        end
      end

      class TempoFactory
        def initialize(livemode:, client:, recipient:, metadata:)
          @livemode = livemode
          @client = client
          @recipient = recipient
          @metadata = metadata
        end

        def configured?
          !@recipient.nil?
        end

        def charge
          raise ArgumentError, "deposit_addresses[:tempo] is required for Tempo payments" unless configured?

          chain_id = @livemode ? Mpp::Methods::Tempo::Defaults::CHAIN_ID : Mpp::Methods::Tempo::Defaults::TESTNET_CHAIN_ID
          currency = @livemode ? Mpp::Methods::Tempo::Defaults::USDC : Mpp::Methods::Tempo::Defaults::PATH_USD
          method = Mpp::Methods::Tempo.tempo(
            intents: {"charge" => Mpp::Methods::Tempo::ChargeIntent.new(chain_id: chain_id)},
            chain_id: chain_id,
            currency: currency,
            recipient: @recipient,
            decimals: Mpp::Methods::Tempo::Defaults::PATH_USD_DECIMALS,
            can_offer: MachinePayments.minimum_amount(CryptoPaymentRecorder::RAW_UNITS_PER_CENT)
          )
          PaymentIntentMethod.new(method: method, client: @client, network: "tempo", metadata: @metadata)
        end
      end

      class BaseFactory
        def initialize(livemode:, client:, recipient:, metadata:)
          @livemode = livemode
          @client = client
          @recipient = recipient
          @metadata = metadata
        end

        def charge(x402:)
          raise ArgumentError, "deposit_addresses[:base] is required for Base payments" if @recipient.nil?

          currency = @livemode ? Mpp::Methods::Evm::Assets::BASE_USDC : Mpp::Methods::Evm::Assets::BASE_SEPOLIA_USDC
          method = Mpp::Methods::Evm.charge(
            currency: currency,
            recipient: @recipient,
            x402: x402,
            can_offer: MachinePayments.minimum_amount(CryptoPaymentRecorder::RAW_UNITS_PER_CENT)
          )
          PaymentIntentMethod.new(method: method, client: @client, network: "base", metadata: @metadata)
        end
      end
    end
  end
end
