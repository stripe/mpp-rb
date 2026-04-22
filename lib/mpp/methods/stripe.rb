# typed: strict
# frozen_string_literal: true

module Mpp
  module Methods
    module Stripe
      autoload :Defaults, "mpp/methods/stripe/defaults"
      # Eagerly require stripe_method so the Stripe.stripe factory method is available
      require_relative "stripe/stripe_method"
      autoload :ChargeIntent, "mpp/methods/stripe/charge_intent"
      autoload :ClientMethod, "mpp/methods/stripe/client_method"
    end
  end
end
