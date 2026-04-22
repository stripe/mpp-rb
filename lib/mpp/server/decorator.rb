# typed: strict
# frozen_string_literal: true

require "json"

module Mpp
  module Server
    module Decorator
      extend T::Sig

      module_function

      # Build a 402 response for a payment challenge with RFC 9457 problem details body.
      sig { params(challenge: T.untyped, realm: T.untyped).returns(T::Hash[T.untyped, T.untyped]) }
      def make_challenge_response(challenge, realm)
        error = Mpp::PaymentRequiredError.new(realm: realm, description: challenge.description)
        body = JSON.generate(error.to_problem_details(challenge_id: challenge.id))
        headers = {
          "WWW-Authenticate" => challenge.to_www_authenticate(realm),
          "Cache-Control" => "no-store",
          "Content-Type" => "application/problem+json"
        }
        {
          "_mpp_challenge" => true,
          "status" => 402,
          "headers" => headers,
          "body" => body
        }
      end
    end
  end
end
