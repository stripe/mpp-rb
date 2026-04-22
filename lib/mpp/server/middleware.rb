# typed: strict
# frozen_string_literal: true

module Mpp
  module Server
    # Rack middleware that intercepts requests requiring payment.
    #
    # The downstream app signals payment is needed by setting env["mpp.charge"]
    # to a hash with at least :amount, and optionally :currency, :recipient,
    # :description, :expires, etc.
    #
    # Example:
    #   use Mpp::Server::Middleware, handler: my_handler
    #
    #   # In your app:
    #   env["mpp.charge"] = { amount: "1.00" }
    class Middleware
      extend T::Sig

      sig { params(app: T.untyped, handler: Mpp::Server::MppHandler).void }
      def initialize(app, handler:)
        @app = T.let(app, T.untyped)
        @handler = T.let(handler, Mpp::Server::MppHandler)
      end

      sig { params(env: T.untyped).returns(T::Array[T.untyped]) }
      def call(env)
        authorization = env["HTTP_AUTHORIZATION"]
        status, headers, body = @app.call(env)

        charge_opts = env["mpp.charge"]
        return [status, headers, body] unless charge_opts

        amount = charge_opts[:amount]
        opts = charge_opts.except(:amount)

        result = @handler.charge(authorization, amount, **opts)

        if result.is_a?(Mpp::Challenge)
          resp = Mpp::Server::Decorator.make_challenge_response(result, @handler.realm)
          return [resp["status"], resp["headers"], [resp["body"]]]
        end

        _credential, receipt = result
        headers["Payment-Receipt"] = receipt.to_payment_receipt

        [status, headers, body]
      end
    end
  end
end
