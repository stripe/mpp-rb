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
      sig { params(authorization: T.nilable(String), intent: T.untyped, request: T::Hash[String, T.untyped], realm: String, secret_key: String, method: T.nilable(String), description: T.nilable(String), meta: T.nilable(T::Hash[String, T.untyped]), expires: T.nilable(String), events: T.nilable(Mpp::Events::Dispatcher), method_hook_events: T.nilable(Mpp::Events::Dispatcher), body: T.untyped, header: T.nilable(String)).returns(T.untyped) }
      def verify_or_challenge(authorization:, intent:, request:, realm:, secret_key:,
        method: nil, description: nil, meta: nil, expires: nil, events: nil, method_hook_events: nil, body: nil, header: nil)
        method_name = method || "tempo"
        request = Mpp::Units.transform_units(request)
        dispatcher = events
        events_enabled = dispatcher&.has_handlers? || method_hook_events&.has_handlers?
        method_context = events_enabled ? {name: method_name, intent: intent.name} : nil

        new_challenge = Kernel.lambda { |credential = nil, error = nil, submitted_challenge = nil|
          challenge = create_challenge(method_name, intent.name, request, realm, secret_key, description, meta, expires, body, header)
          if error && dispatcher&.has_handlers?(Mpp::Events::PAYMENT_FAILED)
            emit_payment_failed(
              dispatcher: dispatcher,
              challenge: challenge,
              credential: credential,
              error: error,
              method: T.must(method_context),
              request: request,
              retry_challenge: challenge,
              submitted_challenge: submitted_challenge
            )
          end
          if dispatcher&.has_handlers?(Mpp::Events::CHALLENGE_CREATED)
            emit_challenge_created(
              dispatcher: dispatcher,
              challenge: challenge,
              credential: credential,
              error: error,
              method: T.must(method_context),
              request: request
            )
          end
          challenge
        }

        return new_challenge.call if authorization.nil?

        payment_scheme = extract_payment_scheme(authorization)
        return new_challenge.call if payment_scheme.nil?

        begin
          credential = Mpp::Credential.from_authorization(payment_scheme)
        rescue Mpp::ParseError => e
          return new_challenge.call(nil, Mpp::MalformedCredentialError.new(reason: e.message))
        end

        # Stateless challenge verification
        echo = credential.challenge
        begin
          echo_request = echo.request.empty? ? {} : Mpp::Parsing.b64_decode(echo.request)
          echo_opaque = (echo.opaque && !T.must(echo.opaque).empty?) ? Mpp::Parsing.b64_decode(echo.opaque) : nil
        rescue Mpp::ParseError => e
          return new_challenge.call(credential, Mpp::MalformedCredentialError.new(reason: e.message), echo)
        end

        expected_id = Mpp.generate_challenge_id(
          secret_key: secret_key,
          realm: echo.realm,
          method: echo.method,
          intent: echo.intent,
          request: echo_request,
          expires: echo.expires,
          digest: echo.digest,
          opaque: echo_opaque,
          header: echo.header
        )
        unless Mpp.secure_compare(echo.id, expected_id)
          return new_challenge.call(
            credential,
            Mpp::InvalidChallengeError.new(challenge_id: echo.id, reason: "challenge id mismatch"),
            echo
          )
        end

        # Assert echoed fields match server's values
        unless echo.realm == realm && echo.method == method_name && echo.intent == intent.name
          return new_challenge.call(
            credential,
            Mpp::InvalidChallengeError.new(challenge_id: echo.id, reason: "challenge binding mismatch"),
            echo
          )
        end

        # Assert echoed request matches server's current request
        unless echo_request == request
          return new_challenge.call(
            credential,
            Mpp::InvalidChallengeError.new(challenge_id: echo.id, reason: "request mismatch"),
            echo
          )
        end

        unless echo_opaque == meta
          return new_challenge.call(
            credential,
            Mpp::InvalidChallengeError.new(challenge_id: echo.id, reason: "metadata mismatch"),
            echo
          )
        end

        unless body_digest_matches?(echo, body)
          return new_challenge.call(
            credential,
            Mpp::InvalidChallengeError.new(challenge_id: echo.id, reason: "body digest mismatch"),
            echo
          )
        end

        # Verify echoed request parameters match endpoint's expected request
        request.each do |key, value|
          unless echo_request[key] == value
            return new_challenge.call(
              credential,
              Mpp::InvalidChallengeError.new(challenge_id: echo.id, reason: "request field #{key} mismatch"),
              echo
            )
          end
        end

        # Enforce challenge expiry - fail closed
        unless echo.expires
          return new_challenge.call(
            credential,
            Mpp::InvalidChallengeError.new(challenge_id: echo.id, reason: "missing expiry"),
            echo
          )
        end

        begin
          expires_dt = Time.iso8601(T.must(echo.expires).gsub("Z", "+00:00"))
        rescue ArgumentError
          return new_challenge.call(
            credential,
            Mpp::InvalidChallengeError.new(challenge_id: echo.id, reason: "invalid expiry"),
            echo
          )
        end
        if expires_dt < Time.now.utc
          return new_challenge.call(credential, Mpp::PaymentExpiredError.new(expires: echo.expires), echo)
        end

        begin
          receipt = intent.verify(credential, request)
        rescue => e
          # Every other verification failure in this function returns a
          # fresh challenge via new_challenge.call (which itself emits
          # payment_failed when an error is present) rather than raising.
          # Method verification failing here — a typed PaymentError or an
          # unexpected error — should be no different: canonical mppx
          # (createMethodFn) treats it as a retryable 402, not an escaped
          # exception. Matches the fix already shipped for the same gap in
          # stripe/mpp-java's Verify.java.
          return new_challenge.call(credential, e, echo)
        end
        if dispatcher&.has_handlers?(Mpp::Events::PAYMENT_SUCCESS) || method_hook_events&.has_handlers?(Mpp::Events::PAYMENT_SUCCESS)
          emit_payment_success(
            dispatcher: dispatcher,
            method_hook_dispatcher: method_hook_events,
            challenge: echo,
            credential: credential,
            method: T.must(method_context),
            receipt: receipt,
            request: request
          )
        end
        [credential, receipt]
      end

      sig { params(method: String, intent_name: String, request: T::Hash[String, T.untyped], realm: String, secret_key: String, description: T.nilable(String), meta: T.nilable(T::Hash[String, T.untyped]), expires: T.nilable(String), body: T.untyped, header: T.nilable(String)).returns(Mpp::Challenge) }
      def create_challenge(method, intent_name, request, realm, secret_key,
        description = nil, meta = nil, expires = nil, body = nil, header = nil)
        expires = nil if expires && !expires.is_a?(String)

        if expires.nil?
          expires_dt = Time.now.utc + (DEFAULT_EXPIRES_MINUTES * 60)
          expires = expires_dt.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
        end
        digest = body.nil? ? nil : Mpp::BodyDigest.compute(body)

        Mpp::Challenge.create(
          secret_key: secret_key,
          realm: realm,
          method: method,
          intent: intent_name,
          request: request,
          expires: expires,
          digest: digest,
          description: description,
          meta: meta,
          header: header
        )
      end

      sig { params(echo: Mpp::ChallengeEcho, body: T.untyped).returns(T::Boolean) }
      def body_digest_matches?(echo, body)
        if body.nil?
          return echo.digest.nil?
        end
        return false unless echo.digest

        Mpp::BodyDigest.verify(T.must(echo.digest), body)
      end

      sig { params(header: String).returns(T.nilable(String)) }
      def extract_payment_scheme(header)
        header.split(",").each do |scheme|
          scheme = scheme.strip
          return scheme if scheme.downcase.start_with?("payment ")
        end
        nil
      end

      sig { params(dispatcher: T.nilable(Mpp::Events::Dispatcher), challenge: T.untyped, credential: T.untyped, error: T.untyped, method: T::Hash[Symbol, T.untyped], request: T::Hash[String, T.untyped]).void }
      def emit_challenge_created(dispatcher:, challenge:, credential:, error:, method:, request:)
        return unless dispatcher&.has_handlers?(Mpp::Events::CHALLENGE_CREATED)

        payload = {
          challenge: challenge,
          method: method,
          request: request
        }
        payload[:credential] = credential unless credential.nil?
        payload[:error] = error unless error.nil?
        dispatcher.emit(Mpp::Events::CHALLENGE_CREATED, payload)
      end

      sig { params(dispatcher: Mpp::Events::Dispatcher, challenge: T.untyped, credential: T.untyped, error: T.untyped, method: T::Hash[Symbol, T.untyped], request: T::Hash[String, T.untyped], retry_challenge: T.untyped, submitted_challenge: T.untyped).void }
      def emit_payment_failed(dispatcher:, challenge:, credential:, error:, method:, request:, retry_challenge: nil, submitted_challenge: nil)
        return unless dispatcher.has_handlers?(Mpp::Events::PAYMENT_FAILED)

        payload = {
          challenge: challenge,
          credential: credential,
          error: error,
          method: method,
          request: request
        }
        payload[:retry_challenge] = retry_challenge unless retry_challenge.nil?
        payload[:submitted_challenge] = submitted_challenge unless submitted_challenge.nil?
        dispatcher.emit(Mpp::Events::PAYMENT_FAILED, payload)
      end

      # Method hooks are owned by a handler, while `dispatcher` may be shared
      # by many handlers. Emit the same payload to each without exposing that
      # handler ownership in the public event payload.
      sig { params(dispatcher: T.nilable(Mpp::Events::Dispatcher), challenge: T.untyped, credential: T.untyped, method: T::Hash[Symbol, T.untyped], receipt: T.untyped, request: T::Hash[String, T.untyped], method_hook_dispatcher: T.nilable(Mpp::Events::Dispatcher)).void }
      def emit_payment_success(dispatcher:, challenge:, credential:, method:, receipt:, request:, method_hook_dispatcher: nil)
        public_handlers = dispatcher&.has_handlers?(Mpp::Events::PAYMENT_SUCCESS)
        hook_handlers = method_hook_dispatcher&.has_handlers?(Mpp::Events::PAYMENT_SUCCESS)
        return unless public_handlers || hook_handlers

        payload = {
          challenge: challenge,
          credential: credential,
          method: method,
          receipt: receipt,
          request: request
        }
        dispatcher.emit(Mpp::Events::PAYMENT_SUCCESS, payload) if public_handlers
        method_hook_dispatcher.emit(Mpp::Events::PAYMENT_SUCCESS, payload) if hook_handlers && method_hook_dispatcher != dispatcher
      end
    end
  end
end
