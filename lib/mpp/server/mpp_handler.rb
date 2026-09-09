# typed: true
# frozen_string_literal: true

require_relative "method"

module Mpp
  module Server
    DEFAULT_DECIMALS = 6

    class MppHandler
      extend T::Sig

      REQUEST_OPTION_KEYS = [:body, :url, :payment_signature, :accept_payment, :http_method, :payment_authorization].freeze

      sig { returns(T.untyped) }
      attr_reader :method

      sig { returns(T::Array[T.untyped]) }
      attr_reader :methods

      sig { returns(String) }
      attr_reader :realm

      sig { returns(String) }
      attr_reader :secret_key

      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :defaults

      sig { returns(T::Boolean) }
      attr_reader :requires_auth

      sig { returns(T.nilable(String)) }
      attr_reader :credential_header

      sig do
        params(
          realm: String,
          secret_key: String,
          method: T.untyped,
          methods: T.nilable(T::Array[T.untyped]),
          defaults: T.nilable(T::Hash[String, T.untyped]),
          events: T.nilable(Mpp::Events::Dispatcher),
          requires_auth: T::Boolean
        ).void
      end
      def initialize(realm:, secret_key:, method: nil, methods: nil, defaults: nil, events: nil, requires_auth: false)
        @methods = T.let(normalize_methods(method, methods), T::Array[T.untyped])
        @method = T.let(@methods.first, T.untyped)
        @realm = T.let(realm, String)
        @secret_key = T.let(secret_key, String)
        @defaults = T.let(defaults || {}, T::Hash[String, T.untyped])
        @events = T.let(events || Mpp::Events.server_dispatcher, Mpp::Events::Dispatcher)
        @method_hook_events = T.let(Mpp::Events.server_dispatcher, Mpp::Events::Dispatcher)
        @requires_auth = T.let(requires_auth, T::Boolean)
        @credential_header = T.let(requires_auth ? Mpp::PAYMENT_AUTHORIZATION_HEADER : nil, T.nilable(String))
        register_method_payment_success
      end

      # Create with auto-detected realm and secret_key.
      sig do
        params(
          method: T.untyped,
          methods: T.nilable(T::Array[T.untyped]),
          realm: T.untyped,
          secret_key: T.untyped,
          events: T.nilable(Mpp::Events::Dispatcher),
          requires_auth: T::Boolean
        ).returns(T.attached_class)
      end
      def self.create(method: nil, methods: nil, realm: nil, secret_key: nil, events: nil, requires_auth: false)
        new(
          method: method,
          methods: methods,
          realm: realm || Defaults.detect_realm,
          secret_key: secret_key || Defaults.detect_secret_key,
          events: events,
          requires_auth: requires_auth
        )
      end

      sig { params(name: String, handler: T.untyped, block: T.nilable(T.proc.params(payload: T.untyped).returns(T.untyped))).returns(T.proc.void) }
      def on(name, handler = nil, &block)
        @events.on(name, handler, &block)
      end

      sig { params(handler: T.untyped, block: T.nilable(T.proc.params(payload: T.untyped).returns(T.untyped))).returns(T.proc.void) }
      def on_challenge_created(handler = nil, &block)
        on(Mpp::Events::CHALLENGE_CREATED, handler, &block)
      end

      sig { params(handler: T.untyped, block: T.nilable(T.proc.params(payload: T.untyped).returns(T.untyped))).returns(T.proc.void) }
      def on_payment_failed(handler = nil, &block)
        on(Mpp::Events::PAYMENT_FAILED, handler, &block)
      end

      sig { params(handler: T.untyped, block: T.nilable(T.proc.params(payload: T.untyped).returns(T.untyped))).returns(T.proc.void) }
      def on_payment_success(handler = nil, &block)
        on(Mpp::Events::PAYMENT_SUCCESS, handler, &block)
      end

      # Select the HTTP header value that carries the Payment credential.
      # When requires_auth is true, Payment credentials ride in
      # Payment-Authorization so Authorization can hold application auth.
      sig { params(authorization: T.nilable(String), payment_authorization: T.nilable(String)).returns(T.nilable(String)) }
      def payment_credential_value(authorization, payment_authorization = nil)
        @requires_auth ? payment_authorization : authorization
      end

      # Combine method offers into a single callable that presents every method.
      sig { params(entries: T.untyped).returns(ComposedHandler) }
      def compose(*entries)
        ComposedHandler.from_entries(self, entries)
      end

      # Look up a registered method by object, name, or "name/intent" key.
      sig { params(method_ref: T.untyped).returns(T.untyped) }
      def resolve_method(method_ref)
        case method_ref
        when String
          resolve_method_key(method_ref)
        else
          found = @methods.find { |candidate| candidate.equal?(method_ref) } ||
            @methods.find { |candidate| candidate.name == method_ref.name }
          return found if found

          raise ArgumentError, "No handler for #{method_ref.inspect}. Is this method in your methods array?"
        end
      end

      # Handle a charge intent.
      #
      # With a single registered charge method this returns Challenge or
      # [Credential, Receipt]. With multiple charge methods it implicitly
      # composes them and returns a ComposedResult.
      sig { params(authorization: T.nilable(String), amount: String, kwargs: T.untyped).returns(T.untyped) }
      def charge(authorization, amount, **kwargs)
        charge_methods = @methods.select { |candidate| candidate.intents.key?("charge") }
        raise ArgumentError, "No registered method supports charge intent" if charge_methods.empty?

        request_opts = kwargs.slice(*REQUEST_OPTION_KEYS)
        offer_opts = kwargs.except(*REQUEST_OPTION_KEYS)
        payment = payment_credential_value(authorization, request_opts[:payment_authorization])

        if charge_methods.length == 1
          return charge_one(
            charge_methods.first,
            payment,
            amount,
            **request_opts,
            **offer_opts
          )
        end

        entries = charge_methods.map { |candidate| [candidate, offer_opts.merge(amount: amount)] }
        ComposedHandler.from_entries(self, entries).call(
          authorization: authorization,
          payment_authorization: request_opts[:payment_authorization],
          payment_signature: request_opts[:payment_signature],
          body: request_opts[:body],
          url: request_opts[:url],
          accept_payment: request_opts[:accept_payment],
          http_method: request_opts[:http_method]
        )
      end

      # Verify or challenge a single method. Used by compose and charge.
      # The optional request guard can omit an offer after its canonical request
      # is built, ensuring the guard and challenge use the exact same request.
      sig { params(method: T.untyped, authorization: T.nilable(String), amount: String, kwargs: T.untyped, request_guard: T.nilable(T.proc.params(request: T::Hash[String, T.untyped]).returns(T::Boolean))).returns(T.untyped) }
      def charge_one(method, authorization, amount, **kwargs, &request_guard)
        intent = method.intents["charge"]
        raise ArgumentError, "Method #{method.name} does not support charge intent" unless intent

        body = kwargs[:body]
        url = kwargs[:url]
        payment_signature = kwargs[:payment_signature]
        offer_opts = kwargs.except(*REQUEST_OPTION_KEYS)
        intent, offer_opts = Mpp::Server::MethodHelper.prepare_intent(method, intent, offer_opts)
        request = build_charge_request(method, amount, **offer_opts)
        return nil if request_guard && !request_guard.call(request)

        if payment_signature && method.respond_to?(:bind_x402_credential)
          return verify_x402(
            method,
            intent,
            request,
            payment_signature: payment_signature,
            url: url,
            body: body,
            description: offer_opts[:description],
            expires: offer_opts[:expires],
            http_method: kwargs[:http_method]
          )
        end

        Verify.verify_or_challenge(
          authorization: authorization,
          intent: intent,
          request: request,
          realm: @realm,
          secret_key: @secret_key,
          method: method.name,
          description: offer_opts[:description],
          expires: offer_opts[:expires],
          events: @events,
          method_hook_events: @method_hook_events,
          body: body,
          header: @credential_header
        )
      end

      # Build the canonical charge request for a method without verifying.
      sig { params(method: T.untyped, amount: String, kwargs: T.untyped).returns(T::Hash[String, T.untyped]) }
      def build_charge_request(method, amount, **kwargs)
        currency = kwargs[:currency]
        recipient = kwargs[:recipient]
        external_id = kwargs[:external_id]
        memo = kwargs[:memo]
        fee_payer = if kwargs.key?(:fee_payer)
          kwargs[:fee_payer]
        else
          method.respond_to?(:fee_payer) && method.fee_payer
        end
        chain_id = kwargs[:chain_id]
        extra = kwargs[:extra]
        mppx_scope = kwargs[:mppx_scope]

        resolved_currency = currency || (method.respond_to?(:currency) ? method.currency : nil)
        resolved_recipient = recipient || (method.respond_to?(:recipient) ? method.recipient : nil)
        raise ArgumentError, "currency must be set on the method or passed to charge()" unless resolved_currency
        raise ArgumentError, "recipient must be set on the method or passed to charge()" unless resolved_recipient

        decimals = method.respond_to?(:decimals) ? method.decimals : DEFAULT_DECIMALS
        base_amount = Mpp::Units.parse_units(amount, decimals).to_s

        request = {
          "amount" => base_amount,
          "currency" => resolved_currency,
          "recipient" => resolved_recipient
        }
        request["externalId"] = external_id unless external_id.nil?

        if extra
          extra.each do |key, value|
            raise ArgumentError, "extra must be a dict[str, str]" unless key.is_a?(String) && value.is_a?(String)
          end
          request["extra"] = extra
        end
        if mppx_scope
          mppx_scope.each do |key, value|
            raise ArgumentError, "mppx_scope must be a dict[str, str]" unless key.is_a?(String) && value.is_a?(String)
          end
          request["_mppx_scope"] = mppx_scope
        end

        resolved_chain_id = chain_id
        resolved_chain_id ||= method.chain_id if method.respond_to?(:chain_id)

        if memo || fee_payer || !resolved_chain_id.nil?
          method_details = {}
          method_details["chainId"] = resolved_chain_id unless resolved_chain_id.nil?
          method_details["memo"] = memo if memo
          method_details["feePayer"] = true if fee_payer
          request["methodDetails"] = method_details
        end

        Mpp::Server::MethodHelper.transform_request(method, request, nil)
      end

      # Render a 402 response, applying method-specific extra headers (x402).
      sig { params(challenge: T.untyped, url: T.nilable(String), http_method: T.nilable(String)).returns(T::Hash[T.untyped, T.untyped]) }
      def challenge_response(challenge, url: nil, http_method: nil)
        challenges = challenge.is_a?(Array) ? challenge : [challenge]
        extra = {}
        if @methods.length == 1 && @method.respond_to?(:decorate_challenge)
          @method.decorate_challenge(extra, challenges.first, url: url, http_method: http_method)
        end
        Decorator.make_challenge_response(challenges, @realm, extra_headers: extra)
      end

      private

      sig { params(method: T.untyped, methods: T.untyped).returns(T::Array[T.untyped]) }
      def normalize_methods(method, methods)
        if !method.nil? && !methods.nil?
          raise ArgumentError, "pass method: or methods:, not both"
        end

        list = methods || (method.nil? ? nil : [method])
        raise ArgumentError, "method: or methods: is required" if list.nil? || list.empty?

        names = list.map(&:name)
        duplicates = names.tally.select { |_name, count| count > 1 }.keys
        raise ArgumentError, "duplicate payment method names: #{duplicates.join(", ")}" unless duplicates.empty?

        list
      end

      sig { params(key: String).returns(T.untyped) }
      def resolve_method_key(key)
        name, intent = key.split("/", 2)
        found = if intent
          @methods.find { |candidate| candidate.name == name && candidate.intents.key?(intent) }
        else
          @methods.find { |candidate| candidate.name == name }
        end
        return found if found

        raise ArgumentError, "No handler for #{key.inspect}. Is this method in your methods array?"
      end

      sig do
        params(
          method: T.untyped,
          intent: T.untyped,
          request: T::Hash[String, T.untyped],
          payment_signature: String,
          url: T.nilable(String),
          body: T.untyped,
          description: T.nilable(String),
          expires: T.nilable(String),
          http_method: T.nilable(String)
        ).returns(T.untyped)
      end
      def verify_x402(method, intent, request, payment_signature:, url:, body:, description:, expires:, http_method: nil)
        challenge = Verify.create_challenge(
          method.name,
          intent.name,
          Mpp::Units.transform_units(request),
          @realm,
          @secret_key,
          description,
          nil,
          expires,
          body,
          @credential_header
        )
        method_context = {name: method.name, intent: intent.name}

        begin
          credential = method.bind_x402_credential(
            payment_signature,
            challenge: challenge,
            request: challenge.request,
            url: url,
            body: body,
            http_method: http_method
          )
          receipt = intent.verify(credential, challenge.request)
        rescue => error
          if @events.has_handlers?(Mpp::Events::PAYMENT_FAILED)
            Verify.emit_payment_failed(
              dispatcher: @events,
              challenge: challenge,
              credential: nil,
              error: error,
              method: method_context,
              request: challenge.request,
              retry_challenge: challenge
            )
          end
          if error.is_a?(Mpp::ParseError) || error.is_a?(Mpp::VerificationError) || error.is_a?(Mpp::PaymentError)
            if @events.has_handlers?(Mpp::Events::CHALLENGE_CREATED)
              Verify.emit_challenge_created(
                dispatcher: @events,
                challenge: challenge,
                credential: nil,
                error: error,
                method: method_context,
                request: challenge.request
              )
            end
            return challenge
          end
          raise
        end

        if @events.has_handlers?(Mpp::Events::PAYMENT_SUCCESS) || @method_hook_events.has_handlers?(Mpp::Events::PAYMENT_SUCCESS)
          Verify.emit_payment_success(
            dispatcher: @events,
            method_hook_dispatcher: @method_hook_events,
            challenge: challenge,
            credential: credential,
            method: method_context,
            receipt: receipt,
            request: challenge.request
          )
        end
        [credential, receipt]
      end

      private

      sig { void }
      def register_method_payment_success
        @methods.each do |payment_method|
          next unless payment_method.respond_to?(:on_payment_success)

          hook = payment_method.on_payment_success
          next if hook.nil?
          raise ArgumentError, "on_payment_success must be callable" unless hook.respond_to?(:call)

          method_name = payment_method.name
          intent_names = payment_method.intents.each_value.map { |intent| intent.name }
          @method_hook_events.on(Mpp::Events::PAYMENT_SUCCESS) do |payload|
            event_method = payload[:method]
            next unless event_method.is_a?(Hash)
            next unless event_method[:name] == method_name
            next unless intent_names.include?(event_method[:intent])

            hook.call(payload)
          end
        end
      end
    end
  end
end
