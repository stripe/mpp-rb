# typed: strict
# frozen_string_literal: true

require_relative "method"

module Mpp
  module Server
    DEFAULT_DECIMALS = 6

    class MppHandler
      extend T::Sig

      sig { returns(T.untyped) }
      attr_reader :method

      sig { returns(String) }
      attr_reader :realm

      sig { returns(String) }
      attr_reader :secret_key

      sig { returns(T::Hash[String, T.untyped]) }
      attr_reader :defaults

      sig { params(method: T.untyped, realm: String, secret_key: String, defaults: T.nilable(T::Hash[String, T.untyped])).void }
      def initialize(method:, realm:, secret_key:, defaults: nil)
        @method = T.let(method, T.untyped)
        @realm = T.let(realm, String)
        @secret_key = T.let(secret_key, String)
        @defaults = T.let(defaults || {}, T::Hash[String, T.untyped])
      end

      # Create with auto-detected realm and secret_key.
      sig { params(method: T.untyped, realm: T.untyped, secret_key: T.untyped).returns(T.attached_class) }
      def self.create(method:, realm: nil, secret_key: nil)
        new(
          method: method,
          realm: realm || Defaults.detect_realm,
          secret_key: secret_key || Defaults.detect_secret_key
        )
      end

      # Handle a charge intent.
      sig { params(authorization: T.nilable(String), amount: String, currency: T.nilable(String), recipient: T.nilable(String), expires: T.nilable(String), description: T.nilable(String), memo: T.nilable(String), fee_payer: T::Boolean, chain_id: T.nilable(Integer), extra: T.nilable(T::Hash[String, String])).returns(T.untyped) }
      def charge(authorization, amount, currency: nil, recipient: nil, expires: nil,
        description: nil, memo: nil, fee_payer: false, chain_id: nil, extra: nil)
        intent = @method.intents["charge"]
        raise ArgumentError, "Method #{@method.name} does not support charge intent" unless intent

        resolved_currency = currency || (@method.respond_to?(:currency) ? @method.currency : nil)
        resolved_recipient = recipient || (@method.respond_to?(:recipient) ? @method.recipient : nil)
        raise ArgumentError, "currency must be set on the method or passed to charge()" unless resolved_currency
        raise ArgumentError, "recipient must be set on the method or passed to charge()" unless resolved_recipient

        decimals = @method.respond_to?(:decimals) ? @method.decimals : DEFAULT_DECIMALS
        base_amount = Mpp::Units.parse_units(amount, decimals).to_s

        request = {
          "amount" => base_amount,
          "currency" => resolved_currency,
          "recipient" => resolved_recipient
        }

        if extra
          extra.each do |k, v|
            raise ArgumentError, "extra must be a dict[str, str]" unless k.is_a?(String) && v.is_a?(String)
          end
          request["extra"] = extra
        end

        resolved_chain_id = chain_id
        resolved_chain_id ||= @method.chain_id if @method.respond_to?(:chain_id)

        if memo || fee_payer || !resolved_chain_id.nil?
          method_details = {}
          method_details["chainId"] = resolved_chain_id unless resolved_chain_id.nil?
          method_details["memo"] = memo if memo
          method_details["feePayer"] = true if fee_payer
          request["methodDetails"] = method_details
        end

        request = Mpp::Server::MethodHelper.transform_request(@method, request, nil)

        Verify.verify_or_challenge(
          authorization: authorization,
          intent: intent,
          request: request,
          realm: @realm,
          secret_key: @secret_key,
          method: @method.name,
          description: description,
          expires: expires
        )
      end
    end
  end
end
