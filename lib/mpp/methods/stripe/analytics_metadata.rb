# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Stripe
      # Builds Stripe-owned metadata used to identify MPP payments.
      module AnalyticsMetadata
        LIMIT = 500

        module_function

        def build(challenge)
          {
            "machine_payment" => "true",
            "mpp_sdk" => "mpp-rb/#{Mpp::VERSION}",
            "mpp_challenge_id" => challenge.id.to_s,
            "mpp_intent" => challenge.intent.to_s
          }.transform_values { |value| value.each_char.first(LIMIT).join }
        end
      end
    end
  end
end
