# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Stripe
      # Validation and deferred resolution for request-scoped PaymentIntent input.
      module PaymentIntentOptions
        module_function

        def validate_input(input)
          return input if input.nil? || input.respond_to?(:call)

          validate(input)
        end

        def resolve(input, challenge:, credential:, request:)
          value = if input.respond_to?(:call)
            input.call(challenge: challenge, credential: credential, request: request)
          else
            input
          end
          return if value.nil?

          validate(value)
        end

        def validate(value)
          raise ArgumentError, "payment_intent_options must be a Hash or callable" unless value.is_a?(Hash)

          input = symbolize(value)
          options = {}
          options[:customer] = non_empty_string(input[:customer], "customer") if input.key?(:customer)
          options[:receipt_email] = non_empty_string(input[:receipt_email], "receipt_email") if input.key?(:receipt_email)
          options[:metadata] = metadata(input[:metadata]) if input.key?(:metadata)
          options[:hooks] = hooks(input[:hooks]) if input.key?(:hooks)
          options.freeze
        end

        def metadata(value)
          raise ArgumentError, "payment_intent_options metadata must be a Hash" unless value.is_a?(Hash)

          value.each_with_object({}) do |(key, entry), result|
            valid_key = key.is_a?(String) || key.is_a?(Symbol)
            unless valid_key && entry.is_a?(String)
              raise ArgumentError, "payment_intent_options metadata must contain string values"
            end
            result[key.to_s] = entry
          end.freeze
        end

        def hooks(value)
          hooks = symbolize_hash(value, "hooks")
          inputs = symbolize_hash(hooks[:inputs], "hooks.inputs")
          tax = symbolize_hash(inputs[:tax], "hooks.inputs.tax")
          calculation = non_empty_string(tax[:calculation], "hooks.inputs.tax.calculation")
          {inputs: {tax: {calculation: calculation}}}.freeze
        end

        def non_empty_string(value, name)
          unless value.is_a?(String) && !value.empty?
            raise ArgumentError, "payment_intent_options #{name} must be a non-empty String"
          end
          value
        end

        def symbolize_hash(value, name)
          raise ArgumentError, "payment_intent_options #{name} must be a Hash" unless value.is_a?(Hash)

          symbolize(value)
        end

        def symbolize(value)
          value.each_with_object({}) do |(key, entry), result|
            result[key.respond_to?(:to_sym) ? key.to_sym : key] = entry
          end
        end
      end
    end
  end
end
