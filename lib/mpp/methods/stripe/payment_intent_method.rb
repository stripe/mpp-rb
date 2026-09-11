# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Stripe
      # Decorates a crypto method with private, request-scoped Stripe input.
      class PaymentIntentMethod
        def initialize(method:, client:, network:, metadata: nil)
          @method = method
          @client = client
          @network = network
          @metadata = metadata
        end

        def prepare_intent(intent, input)
          options_input = input[:payment_intent_options]
          PaymentIntentOptions.validate_input(options_input)
          sanitized = input.except(:payment_intent_options)
          decorated = WrappedIntent.new(
            intent: intent,
            options_input: options_input,
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

        # Per-attempt intent view retaining resolved input outside protocol state.
        class WrappedIntent
          attr_reader :name

          def initialize(intent:, options_input:, client:, network:, metadata:)
            @intent = intent
            @name = intent.name
            @options_input = options_input
            @client = client
            @network = network
            @metadata = metadata

            # Mirror the rail's capabilities so server dispatch can validate
            # before entering the terminal operation that resolves options.
            if intent.respond_to?(:validate)
              define_singleton_method(:validate) do |credential, request|
                @intent.validate(credential, request)
              end
            end
            if intent.respond_to?(:broadcast)
              define_singleton_method(:broadcast) do |credential, request|
                options = resolve_options(credential, request)
                receipt = @intent.broadcast(credential, request)
                record_payment(credential, request, receipt, options)
              end
            end
          end

          # @deprecated Use #validate and #broadcast when supported by the rail.
          def verify(credential, request)
            if respond_to?(:validate) || respond_to?(:broadcast)
              return Mpp::Server::IntentLifecycle.call(self, credential, request)
            end

            options = resolve_options(credential, request)
            receipt = @intent.verify(credential, request)
            record_payment(credential, request, receipt, options)
          end

          private

          def resolve_options(credential, request)
            PaymentIntentOptions.resolve(
              @options_input,
              challenge: credential.challenge,
              credential: credential,
              request: request
            )
          end

          def record_payment(credential, request, receipt, options)
            CryptoPaymentRecorder.new(client: @client, network: @network, metadata: @metadata).call(
              challenge: credential.challenge,
              receipt: receipt,
              request: request,
              payment_intent_options: options
            )
            receipt
          end
        end
      end
    end
  end
end
