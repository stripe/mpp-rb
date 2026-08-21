# typed: true
# frozen_string_literal: true

module Mpp
  module Methods
    module Evm
      autoload :Assets, "mpp/methods/evm/assets"
      autoload :Authorization, "mpp/methods/evm/authorization"
      autoload :ChargeIntent, "mpp/methods/evm/charge_intent"
      autoload :EvmMethod, "mpp/methods/evm/evm_method"
      autoload :Keccak, "mpp/methods/evm/keccak"

      # Factory for a server-side EVM charge method with inline x402 exact support.
      def self.charge(currency:, recipient:, x402:, authorization: nil, chain_id: nil, decimals: nil)
        resolved = Assets.resolve(
          currency,
          authorization: authorization,
          chain_id: chain_id,
          decimals: decimals
        )
        x402_options = normalize_x402(x402)

        charge_intent = ChargeIntent.new(
          authorization: resolved.fetch(:authorization),
          facilitator: X402::Facilitator.resolve(x402_options.fetch(:facilitator)),
          max_timeout_seconds: x402_options.fetch(:max_timeout_seconds),
          route_binding: x402_options.fetch(:route_binding)
        )

        method = EvmMethod.new(
          currency: resolved.fetch(:address),
          recipient: recipient,
          decimals: resolved.fetch(:decimals),
          chain_id: resolved.fetch(:chain_id),
          authorization: resolved.fetch(:authorization),
          x402: x402_options
        )
        method.intents = {"charge" => charge_intent}
        method
      end

      def self.normalize_x402(x402)
        options = x402.each_with_object({}) do |(key, value), acc|
          acc[key.to_sym] = value
        end
        facilitator = options[:facilitator]
        raise ArgumentError, "evm.charge requires x402: { facilitator: ... }" if facilitator.nil? || facilitator.to_s.empty?

        route_binding = (options[:route_binding] || options[:routeBinding] || :resource).to_sym
        unless [:resource, :required].include?(route_binding)
          raise ArgumentError, "x402 route_binding must be :resource or :required"
        end

        {
          facilitator: facilitator,
          max_timeout_seconds: Integer(options[:max_timeout_seconds] || options[:maxTimeoutSeconds] || 300),
          route_binding: route_binding
        }
      end
      private_class_method :normalize_x402
    end
  end
end
