# typed: strict
# frozen_string_literal: true

require "time"

module Mpp
  module Server
    module Verify
      extend T::Sig

      DEFAULT_EXPIRES_MINUTES = 5

      module_function

      # Verify a payment credential or generate a new challenge.
      #
      # Returns Challenge (payment required) or [Credential, Receipt] (verified).
      sig { params(authorization: T.nilable(String), intent: T.untyped, request: T::Hash[String, T.untyped], realm: String, secret_key: String, method: T.nilable(String), description: T.nilable(String), meta: T.nilable(T::Hash[String, T.untyped]), expires: T.nilable(String)).returns(T.untyped) }
      def verify_or_challenge(authorization:, intent:, request:, realm:, secret_key:,
        method: nil, description: nil, meta: nil, expires: nil)
        method_name = method || "tempo"
        request = Mpp::Units.transform_units(request)

        new_challenge = Kernel.lambda {
          create_challenge(method_name, intent.name, request, realm, secret_key, description, meta, expires)
        }

        return new_challenge.call if authorization.nil?

        payment_scheme = extract_payment_scheme(authorization)
        return new_challenge.call if payment_scheme.nil?

        begin
          credential = Mpp::Credential.from_authorization(payment_scheme)
        rescue Mpp::ParseError
          return new_challenge.call
        end

        # Stateless challenge verification
        echo = credential.challenge
        begin
          echo_request = echo.request.empty? ? {} : Mpp::Parsing.b64_decode(echo.request)
          echo_opaque = (echo.opaque && !T.must(echo.opaque).empty?) ? Mpp::Parsing.b64_decode(echo.opaque) : nil
        rescue Mpp::ParseError
          return new_challenge.call
        end

        expected_id = Mpp.generate_challenge_id(
          secret_key: secret_key,
          realm: echo.realm,
          method: echo.method,
          intent: echo.intent,
          request: echo_request,
          expires: echo.expires,
          digest: echo.digest,
          opaque: echo_opaque
        )
        return new_challenge.call unless Mpp.secure_compare(echo.id, expected_id)

        # Assert echoed fields match server's values
        return new_challenge.call unless echo.realm == realm && echo.method == method_name && echo.intent == intent.name

        # Assert echoed request matches server's current request
        return new_challenge.call unless echo_request == request

        return new_challenge.call unless echo_opaque == meta

        # Reject expired challenges as defense-in-depth
        if echo.expires
          begin
            expires_dt = Time.iso8601(T.must(echo.expires).gsub("Z", "+00:00"))
            return new_challenge.call if expires_dt < Time.now.utc
          rescue ArgumentError
            # If we can't parse, continue to stricter check below
          end
        end

        # Verify echoed request parameters match endpoint's expected request
        request.each do |key, value|
          return new_challenge.call unless echo_request[key] == value
        end

        # Enforce challenge expiry - fail closed
        return new_challenge.call unless echo.expires

        begin
          expires_dt = Time.iso8601(T.must(echo.expires).gsub("Z", "+00:00"))
        rescue ArgumentError
          return new_challenge.call
        end
        return new_challenge.call if expires_dt < Time.now.utc

        receipt = intent.verify(credential, request)
        [credential, receipt]
      end

      sig { params(method: String, intent_name: String, request: T::Hash[String, T.untyped], realm: String, secret_key: String, description: T.nilable(String), meta: T.nilable(T::Hash[String, T.untyped]), expires: T.nilable(String)).returns(Mpp::Challenge) }
      def create_challenge(method, intent_name, request, realm, secret_key,
        description = nil, meta = nil, expires = nil)
        expires = nil if expires && !expires.is_a?(String)

        if expires.nil?
          expires_dt = Time.now.utc + (DEFAULT_EXPIRES_MINUTES * 60)
          expires = expires_dt.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
        end

        Mpp::Challenge.create(
          secret_key: secret_key,
          realm: realm,
          method: method,
          intent: intent_name,
          request: request,
          expires: expires,
          description: description,
          meta: meta
        )
      end

      sig { params(header: String).returns(T.nilable(String)) }
      def extract_payment_scheme(header)
        header.split(",").each do |scheme|
          scheme = scheme.strip
          return scheme if scheme.downcase.start_with?("payment ")
        end
        nil
      end
    end
  end
end
