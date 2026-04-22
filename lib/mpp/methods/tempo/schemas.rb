# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Tempo
      module Schemas
        HEX_PATTERN = /\A0x[a-fA-F0-9]+\z/

        MethodDetails = Data.define(:chain_id, :fee_payer, :fee_payer_url, :memo) do
          def initialize(chain_id: 4217, fee_payer: false, fee_payer_url: nil, memo: nil)
            super
          end

          def self.from_hash(hash)
            return new unless hash.is_a?(Hash)

            new(
              chain_id: hash["chainId"] || 4217,
              fee_payer: hash["feePayer"] || false,
              fee_payer_url: hash["feePayerUrl"],
              memo: hash["memo"]
            )
          end
        end

        ChargeRequest = Data.define(:amount, :currency, :recipient, :description,
          :external_id, :method_details) do
          def initialize(amount:, currency:, recipient:, description: nil,
            external_id: nil, method_details: nil)
            raise ArgumentError, "currency must be a hex address" unless currency.match?(HEX_PATTERN)
            raise ArgumentError, "recipient must be a hex address" unless recipient.match?(HEX_PATTERN)

            method_details ||= MethodDetails.new
            super
          end

          def self.from_hash(hash)
            new(
              amount: hash["amount"],
              currency: hash["currency"],
              recipient: hash["recipient"],
              description: hash["description"],
              external_id: hash["externalId"],
              method_details: MethodDetails.from_hash(hash["methodDetails"])
            )
          end
        end

        HashCredentialPayload = Data.define(:type, :hash) do
          def initialize(type:, hash:)
            raise ArgumentError, "type must be 'hash'" unless type == "hash"
            raise ArgumentError, "hash must be a hex string" unless hash.match?(HEX_PATTERN)

            super
          end
        end

        TransactionCredentialPayload = Data.define(:type, :signature) do
          def initialize(type:, signature:)
            raise ArgumentError, "type must be 'transaction'" unless type == "transaction"
            raise ArgumentError, "signature must be a hex string" unless signature.match?(HEX_PATTERN)

            super
          end
        end

        ProofCredentialPayload = Data.define(:type, :signature) do
          def initialize(type:, signature:)
            raise ArgumentError, "type must be 'proof'" unless type == "proof"
            raise ArgumentError, "signature must be a hex string" unless signature.match?(HEX_PATTERN)

            super
          end
        end

        module_function

        def parse_credential_payload(data)
          Kernel.raise ArgumentError, "Invalid credential payload" unless data.is_a?(Hash) && data.key?("type")

          case data["type"]
          when "hash"
            HashCredentialPayload.new(type: "hash", hash: data["hash"])
          when "transaction"
            TransactionCredentialPayload.new(type: "transaction", signature: data["signature"])
          when "proof"
            ProofCredentialPayload.new(type: "proof", signature: data["signature"])
          else
            Kernel.raise ArgumentError, "Invalid credential type: #{data["type"]}"
          end
        end
      end
    end
  end
end
