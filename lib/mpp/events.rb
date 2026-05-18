# typed: strict
# frozen_string_literal: true

module Mpp
  module Events
    extend T::Sig

    ANY = "*"
    CHALLENGE_CREATED = "challenge.created"
    CHALLENGE_RECEIVED = "challenge.received"
    CREDENTIAL_CREATED = "credential.created"
    PAYMENT_FAILED = "payment.failed"
    PAYMENT_RESPONSE = "payment.response"
    PAYMENT_SUCCESS = "payment.success"

    Event = Data.define(:name, :payload)

    class Dispatcher
      extend T::Sig

      sig { params(event_names: T::Array[String]).void }
      def initialize(event_names:)
        @event_names = T.let(event_names.to_h { |name| [name, true] }, T::Hash[String, T::Boolean])
        @event_names[ANY] = true
        @handlers = T.let(@event_names.keys.to_h { |name| [name, []] }, T::Hash[String, T::Array[T.untyped]])
      end

      sig { params(name: String, handler: T.nilable(T.untyped), block: T.nilable(T.proc.params(payload: T.untyped).returns(T.untyped))).returns(T.proc.void) }
      def on(name, handler = nil, &block)
        raise ArgumentError, "Unknown event: #{name}" unless @event_names.key?(name)

        callback = handler || block
        raise ArgumentError, "handler is required" unless callback

        @handlers[name] << callback
        Kernel.lambda { @handlers[name].delete(callback) }
      end

      sig { params(name: String, payload: T::Hash[Symbol, T.untyped]).void }
      def emit(name, payload)
        return unless has_handlers?(name)

        emit_observers(name, payload)
        emit_any(name, payload)
      end

      sig { params(name: String, payload: T::Hash[Symbol, T.untyped]).returns(T.untyped) }
      def emit_first(name, payload)
        return nil unless has_handlers?(name)

        result = nil

        T.must(@handlers[name]).each do |handler|
          value = call(handler, payload)
          next if empty_result?(value)

          result = value
          break
        end

        emit_any(name, payload)
        result
      end

      sig { params(name: T.nilable(String)).returns(T::Boolean) }
      def has_handlers?(name = nil)
        return @handlers.any? { |_event_name, handlers| !handlers.empty? } unless name

        !T.must(@handlers[name]).empty? || !T.must(@handlers[ANY]).empty?
      end

      private

      sig { params(name: String, payload: T::Hash[Symbol, T.untyped]).void }
      def emit_observers(name, payload)
        T.must(@handlers[name]).each { |handler| call(handler, payload) }
      end

      sig { params(name: String, payload: T::Hash[Symbol, T.untyped]).void }
      def emit_any(name, payload)
        any_handlers = T.must(@handlers[ANY])
        return if any_handlers.empty?

        event = Event.new(name: name, payload: payload)
        any_handlers.each { |handler| call(handler, event) }
      end

      sig { params(handler: T.untyped, payload: T.untyped).returns(T.untyped) }
      def call(handler, payload)
        handler.call(payload)
      rescue
        nil
      end

      sig { params(value: T.untyped).returns(T::Boolean) }
      def empty_result?(value)
        value.nil? || (value.respond_to?(:empty?) && value.empty?)
      end
    end

    sig { returns(Dispatcher) }
    def self.client_dispatcher
      Dispatcher.new(event_names: [
        CHALLENGE_RECEIVED,
        CREDENTIAL_CREATED,
        PAYMENT_FAILED,
        PAYMENT_RESPONSE
      ])
    end

    sig { returns(Dispatcher) }
    def self.server_dispatcher
      Dispatcher.new(event_names: [
        CHALLENGE_CREATED,
        PAYMENT_FAILED,
        PAYMENT_SUCCESS
      ])
    end
  end
end
