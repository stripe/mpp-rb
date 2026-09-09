# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Stripe
      # Decorates a machine-payment method with private, request-scoped Stripe input.
      class PaymentIntentMethod
        def initialize(method:, client: nil, network: nil, metadata: nil)
          @method = method
          @client = client
          @network = network
          @metadata = metadata
        end

        def prepare_intent(intent, input)
          has_options = input.key?(:payment_intent_options)
          options_input = input[:payment_intent_options]
          PaymentIntentOptions.validate_input(options_input)
          sanitized = input.except(:payment_intent_options)
          decorated = PaymentIntentIntent.new(
            intent: intent,
            options_input: options_input,
            has_options: has_options,
            client: @client,
            network: @network,
            metadata: @metadata
          )
          [decorated, sanitized]
        end

        def method_missing(name, *args, **kwargs, &block)
          return super unless @method.respond_to?(name)

          @method.public_send(name, *args, **kwargs, &block)
        end

        def respond_to_missing?(name, include_private = false)
          @method.respond_to?(name, include_private) || super
        end
      end

      # Per-attempt intent view retaining resolved input outside protocol state.
      class PaymentIntentIntent
        attr_reader :name

        def initialize(intent:, options_input:, has_options:, client:, network:, metadata:)
          @intent = intent
          @name = intent.name
          @options_input = options_input
          @has_options = has_options
          @client = client
          @network = network
          @metadata = metadata
        end

        def verify(credential, request)
          challenge = PaymentIntentOptions.challenge_view(credential.challenge, request)
          resolved_options = nil
          receipt = @intent.verify(credential, request) do
            resolved_options = PaymentIntentOptions.resolve(
              @options_input,
              challenge: challenge,
              credential: credential,
              request: request
            )
          end

          if @network
            CryptoPaymentRecorder.new(client: @client, network: @network, metadata: @metadata).call(
              challenge: challenge,
              receipt: receipt,
              request: request,
              payment_intent_options: resolved_options,
              has_payment_intent_options: @has_options
            )
          end
          receipt
        end
      end
    end
  end
end
