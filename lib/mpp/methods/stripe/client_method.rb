# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Stripe
      # Client-side Stripe method for creating SPT-based credentials.
      class ClientMethod
        attr_reader :name

        def initialize(create_spt:, payment_method: nil, external_id: nil)
          @name = "stripe"
          @create_spt = create_spt
          @payment_method = payment_method
          @external_id = external_id
        end

        # Create a credential to satisfy the given challenge.
        def create_credential(challenge)
          request = challenge.request
          method_details = request["methodDetails"]
          method_details = {} unless method_details.is_a?(Hash)

          spt_id = @create_spt.call(
            amount: request["amount"],
            currency: request["currency"],
            network_id: method_details["networkId"],
            payment_method: @payment_method
          )

          payload = {"spt" => spt_id}
          payload["externalId"] = @external_id if @external_id

          Mpp::Credential.new(
            challenge: challenge.to_echo,
            payload: payload
          )
        end
      end
    end
  end
end
