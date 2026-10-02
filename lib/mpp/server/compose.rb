# typed: true
# frozen_string_literal: true

require_relative "result"
require_relative "accept_payment"

module Mpp
  module Server
    extend T::Sig

    # A configured payment offer: a method plus per-request charge options.
    class ComposeOffer
      extend T::Sig

      sig { returns(T.untyped) }
      attr_reader :method

      sig { returns(T::Hash[Symbol, T.untyped]) }
      attr_reader :options

      sig { params(handler: T.untyped, method: T.untyped, options: T::Hash[T.untyped, T.untyped]).void }
      def initialize(handler, method, options)
        @handler = T.let(handler, T.untyped)
        @method = T.let(method, T.untyped)
        @options = T.let(symbolize(options), T::Hash[Symbol, T.untyped])
        amount = @options[:amount]
        Kernel.raise ArgumentError, "compose entry requires amount:" if amount.nil? || amount.to_s.empty?
      end

      sig { returns(String) }
      def intent_name
        "charge"
      end

      sig { returns(String) }
      def key
        "#{@method.name}/#{intent_name}"
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def canonical_request
        @canonical_request ||= @handler.build_charge_request(@method, amount, **charge_kwargs)
      end

      sig { params(authorization: T.nilable(String), payment_signature: T.nilable(String), body: T.untyped, url: T.nilable(String), http_method: T.nilable(String), request_guard: T.nilable(T.proc.params(request: T::Hash[String, T.untyped]).returns(T::Boolean))).returns(T.untyped) }
      def verify(authorization: nil, payment_signature: nil, body: nil, url: nil, http_method: nil, &request_guard)
        @handler.charge_one(
          @method,
          authorization,
          amount,
          payment_signature: payment_signature,
          url: url,
          body: body,
          http_method: http_method,
          **charge_kwargs,
          &request_guard
        )
      end

      sig { params(body: T.untyped, url: T.nilable(String), http_method: T.nilable(String)).returns(T.nilable(Mpp::Challenge)) }
      def challenge(body: nil, url: nil, http_method: nil)
        result = verify(body: body, url: url, http_method: http_method) do |request|
          Mpp::Server::MethodHelper.can_offer?(@method, request)
        end
        return nil if result.nil?
        return result if result.is_a?(Mpp::Challenge)

        Kernel.raise "expected a challenge from unpaid offer #{key}"
      end

      sig { params(headers: T::Hash[String, T.untyped], challenge: Mpp::Challenge, url: T.nilable(String), http_method: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
      def decorate_challenge(headers, challenge, url: nil, http_method: nil)
        return headers unless @method.respond_to?(:decorate_challenge)

        @method.decorate_challenge(headers, challenge, url: url, http_method: http_method, request: challenge.request)
        headers
      end

      sig { params(headers: T::Hash[String, T.untyped], credential: T.untyped, receipt: Mpp::Receipt, payment_signature: T.nilable(String)).returns(T::Hash[String, T.untyped]) }
      def decorate_receipt(headers, credential, receipt, payment_signature: nil)
        return headers unless payment_signature && @method.respond_to?(:decorate_receipt)

        @method.decorate_receipt(headers, receipt, credential, payment_signature: payment_signature)
        headers
      end

      sig { params(payload: T::Hash[T.untyped, T.untyped]).returns(T::Boolean) }
      def x402_matches?(payload)
        return false unless @method.respond_to?(:x402_matches?)

        @method.x402_matches?(payload, canonical_request)
      end

      # Return a per-request offer bound to the Rack request scope.
      sig { params(scope: T::Hash[String, String]).returns(ComposeOffer) }
      def with_scope(scope)
        ComposeOffer.new(@handler, @method, @options.merge(mppx_scope: @options[:mppx_scope] || scope.dup))
      end

      private

      sig { returns(String) }
      def amount
        @options[:amount].to_s
      end

      REQUEST_OPTION_KEYS = [:body, :url, :payment_signature, :accept_payment, :authorization, :http_method, :payment_authorization].freeze

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def charge_kwargs
        @options.except(:amount, *REQUEST_OPTION_KEYS)
      end

      sig { params(options: T::Hash[T.untyped, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def symbolize(options)
        options.each_with_object({}) do |(key, value), acc|
          acc[key.to_sym] = value
        end
      end
    end

    # Combines multiple method offers into a single callable that presents
    # every method via multiple WWW-Authenticate headers (and x402 extras).
    class ComposedHandler
      extend T::Sig

      sig { returns(T.untyped) }
      attr_reader :handler

      sig { returns(T::Array[ComposeOffer]) }
      attr_reader :offers

      sig { params(handler: T.untyped, offers: T::Array[ComposeOffer]).void }
      def initialize(handler:, offers:)
        Kernel.raise ArgumentError, "compose() requires at least one entry" if offers.empty?

        @handler = T.let(handler, T.untyped)
        @offers = T.let(offers, T::Array[ComposeOffer])
      end

      sig { params(handler: T.untyped, entries: T::Array[T.untyped]).returns(ComposedHandler) }
      def self.from_entries(handler, entries)
        new(handler: handler, offers: entries.flat_map { |entry| offers_from_entry(handler, entry) })
      end

      # Flatten nested compositions into a single handler.
      sig { params(handlers: T::Array[T.untyped]).returns(ComposedHandler) }
      def self.compose(handlers)
        Kernel.raise ArgumentError, "compose() requires at least one handler" if handlers.empty?

        offers = handlers.flat_map do |value|
          if value.is_a?(ComposedHandler)
            value.offers
          elsif value.respond_to?(:offers)
            value.offers
          else
            Kernel.raise ArgumentError, "compose() expected a ComposedHandler, got #{value.class}"
          end
        end
        new(handler: handlers.first.handler, offers: offers)
      end

      sig do
        params(
          authorization: T.nilable(String),
          payment_authorization: T.nilable(String),
          payment_signature: T.nilable(String),
          body: T.untyped,
          url: T.nilable(String),
          accept_payment: T.nilable(String),
          http_method: T.nilable(String),
          scope: T.nilable(T::Hash[String, String])
        ).returns(ComposedResult)
      end
      def call(authorization: nil, payment_authorization: nil, payment_signature: nil, body: nil, url: nil, accept_payment: nil, http_method: nil, scope: nil)
        if scope && !scope.empty?
          return self.class.new(handler: @handler, offers: @offers.map { |offer| offer.with_scope(scope) }).call(
            authorization: authorization,
            payment_authorization: payment_authorization,
            payment_signature: payment_signature,
            body: body,
            url: url,
            accept_payment: accept_payment,
            http_method: http_method
          )
        end

        credential = @handler.payment_credential_value(authorization, payment_authorization)
        dispatched = dispatch_credential(
          authorization: credential,
          payment_signature: payment_signature,
          body: body,
          url: url,
          http_method: http_method
        )
        return dispatched if dispatched

        merge_challenges(body: body, url: url, accept_payment: accept_payment, http_method: http_method)
      end

      private

      # A method accepting several currencies yields one offer per currency.
      sig { params(handler: T.untyped, entry: T.untyped).returns(T::Array[ComposeOffer]) }
      def self.offers_from_entry(handler, entry)
        unless entry.is_a?(Array) && entry.length == 2
          Kernel.raise ArgumentError, "compose() entries must be [method, options] tuples"
        end

        method_ref, options = entry
        options = {} if options.nil?
        unless options.is_a?(Hash)
          Kernel.raise ArgumentError, "compose() options must be a Hash"
        end

        method = handler.resolve_method(method_ref)
        currencies = Mpp::Server::MethodHelper.offer_currencies(method, options)
        return [ComposeOffer.new(handler, method, options)] if currencies.nil?

        currencies.map { |currency| ComposeOffer.new(handler, method, options.merge(currency: currency)) }
      end
      private_class_method :offers_from_entry

      sig do
        params(
          authorization: T.nilable(String),
          payment_signature: T.nilable(String),
          body: T.untyped,
          url: T.nilable(String),
          http_method: T.nilable(String)
        ).returns(T.nilable(ComposedResult))
      end
      def dispatch_credential(authorization:, payment_signature:, body:, url:, http_method: nil)
        if payment_signature && !payment_signature.strip.empty?
          result = dispatch_x402(payment_signature, body: body, url: url, http_method: http_method)
          return result if result
        end

        return nil if authorization.nil? || authorization.strip.empty?

        dispatch_authorization(authorization, body: body, url: url, http_method: http_method)
      end

      sig { params(payment_signature: String, body: T.untyped, url: T.nilable(String), http_method: T.nilable(String)).returns(T.nilable(ComposedResult)) }
      def dispatch_x402(payment_signature, body:, url:, http_method: nil)
        payload = decode_x402_payload(payment_signature)
        return nil unless payload

        offer = @offers.find { |candidate| candidate.x402_matches?(payload) }
        return nil unless offer

        wrap_offer_result(
          offer.verify(payment_signature: payment_signature, body: body, url: url, http_method: http_method),
          offer,
          payment_signature: payment_signature,
          url: url,
          http_method: http_method
        )
      end

      sig { params(authorization: String, body: T.untyped, url: T.nilable(String), http_method: T.nilable(String)).returns(T.nilable(ComposedResult)) }
      def dispatch_authorization(authorization, body:, url:, http_method: nil)
        payment = Mpp::Server::Verify.extract_payment_scheme(authorization)
        return nil unless payment

        begin
          credential = Mpp::Credential.from_authorization(payment)
        rescue Mpp::ParseError
          return nil
        end

        offer = matching_offer(credential)
        return nil unless offer

        wrap_offer_result(
          offer.verify(authorization: authorization, body: body, url: url, http_method: http_method),
          offer,
          url: url,
          http_method: http_method
        )
      end

      sig { params(credential: Mpp::Credential).returns(T.nilable(ComposeOffer)) }
      def matching_offer(credential)
        echo = credential.challenge
        echo_request = decode_echo_request(echo)
        return nil if echo_request.nil?

        candidates = @offers.select do |offer|
          offer.method.name == echo.method && offer.intent_name == echo.intent
        end
        return nil if candidates.empty?

        exact = candidates.select { |offer| offer.canonical_request == echo_request }
        exact.first || candidates.first
      end

      sig { params(echo: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def decode_echo_request(echo)
        return {} if echo.request.nil? || echo.request.empty?

        Mpp::Parsing.b64_decode(echo.request)
      rescue Mpp::ParseError
        nil
      end

      sig { params(payment_signature: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def decode_x402_payload(payment_signature)
        Mpp::X402::Header.decode_payment_signature(payment_signature)
      rescue Mpp::ParseError, ArgumentError
        nil
      end

      sig do
        params(
          result: T.untyped,
          offer: ComposeOffer,
          payment_signature: T.nilable(String),
          url: T.nilable(String),
          http_method: T.nilable(String)
        ).returns(ComposedResult)
      end
      def wrap_offer_result(result, offer, payment_signature: nil, url: nil, http_method: nil)
        if result.is_a?(Mpp::Challenge)
          extra = {}
          offer.decorate_challenge(extra, result, url: url, http_method: http_method)
          return ComposedResult.payment_required([result], realm: @handler.realm, extra_headers: extra)
        end

        credential, receipt = result
        extra = {}
        offer.decorate_receipt(extra, credential, receipt, payment_signature: payment_signature)
        ComposedResult.paid(credential, receipt, realm: @handler.realm, extra_headers: extra)
      end

      sig do
        params(
          body: T.untyped,
          url: T.nilable(String),
          accept_payment: T.nilable(String),
          http_method: T.nilable(String)
        ).returns(ComposedResult)
      end
      def merge_challenges(body:, url:, accept_payment:, http_method:)
        pairs = @offers.filter_map do |offer|
          challenge = offer.challenge(body: body, url: url, http_method: http_method)
          next if challenge.nil?

          [offer, challenge]
        end
        if pairs.empty?
          Kernel.raise ArgumentError, "No payment offers are available for this request"
        end

        ranked = AcceptPayment.apply(pairs.map { |_offer, challenge| challenge }, accept_payment)
        by_id = pairs.to_h { |offer, challenge| [challenge.id, [offer, challenge]] }
        pairs = ranked.filter_map { |challenge| by_id[challenge.id] }

        extra = merge_extra_headers(pairs, url: url, http_method: http_method)
        ComposedResult.payment_required(pairs.map { |_offer, challenge| challenge }, realm: @handler.realm, extra_headers: extra)
      end

      sig do
        params(
          pairs: T::Array[T.untyped],
          url: T.nilable(String),
          http_method: T.nilable(String)
        ).returns(T::Hash[String, T.untyped])
      end
      def merge_extra_headers(pairs, url:, http_method:)
        extra = {}
        required_headers = []
        pairs.each do |offer, challenge|
          headers = {}
          offer.decorate_challenge(headers, challenge, url: url, http_method: http_method)
          required = headers["PAYMENT-REQUIRED"]
          required_headers << required if required
          headers.each do |key, value|
            next if key == "PAYMENT-REQUIRED"

            extra[key] = value
          end
        end

        merged = merge_payment_required(required_headers)
        extra["PAYMENT-REQUIRED"] = merged if merged
        extra
      end

      sig { params(values: T::Array[String]).returns(T.nilable(String)) }
      def merge_payment_required(values)
        return nil if values.empty?
        return values.first if values.length == 1

        Mpp::X402::Server.merge_payment_required(values)
      end
    end

    sig { params(handlers: T.untyped).returns(ComposedHandler) }
    def self.compose(*handlers)
      ComposedHandler.compose(handlers)
    end
  end
end
