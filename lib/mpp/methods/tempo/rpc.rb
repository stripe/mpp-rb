# typed: false
# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module Mpp
  module Methods
    module Tempo
      module Rpc
        DEFAULT_TIMEOUT = 30

        module_function

        def resolve(provider = nil)
          provider ||= self
          unless provider.respond_to?(:call)
            raise ArgumentError, "rpc provider must respond to call(rpc_url, method, params)"
          end

          provider
        end

        # Make a JSON-RPC call.
        def call(rpc_url, method, params, client: nil)
          payload = {"jsonrpc" => "2.0", "method" => method, "params" => params, "id" => 1}

          uri = URI.parse(rpc_url)
          http = client || Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https" unless client
          http.read_timeout = DEFAULT_TIMEOUT unless client

          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(payload)

          response = http.request(request)
          result = JSON.parse(response.body)

          Kernel.raise "RPC error: #{result["error"]}" if result.key?("error")

          result["result"]
        end

        # Fetch chain_id, nonce, and gas_price.
        def get_tx_params(rpc_url, sender, client: nil, provider: self)
          # In Ruby, we make these calls sequentially (or use threads)
          chain_id_hex = provider_call(provider, rpc_url, "eth_chainId", [], client: client)
          nonce_hex = provider_call(provider, rpc_url, "eth_getTransactionCount", [sender, "pending"], client: client)
          gas_hex = provider_call(provider, rpc_url, "eth_gasPrice", [], client: client)

          [chain_id_hex.to_i(16), nonce_hex.to_i(16), gas_hex.to_i(16)]
        end

        # Estimate gas for a call.
        def estimate_gas(rpc_url, from_addr, to, data, client: nil, provider: self)
          result = provider_call(
            provider,
            rpc_url,
            "eth_estimateGas",
            [{"from" => from_addr, "to" => to, "data" => data}, "latest"],
            client: client
          )
          result.to_i(16)
        end

        def provider_call(provider, rpc_url, method, params, client: nil)
          return call(rpc_url, method, params, client: client) if provider.equal?(self)

          provider.call(rpc_url, method, params)
        end
        private_class_method :provider_call
      end
    end
  end
end
