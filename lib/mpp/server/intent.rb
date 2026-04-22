# typed: strict
# frozen_string_literal: true

module Mpp
  module Server
    extend T::Sig

    # Intent interface (duck type):
    #   name  -> String
    #   verify(credential, request) -> Receipt
    #
    # Implement this interface for custom payment intents.

    # Function-based intent wrapper.
    class FunctionalIntent
      extend T::Sig

      sig { returns(String) }
      attr_reader :name

      sig { params(name: String, verify_fn: T.proc.params(arg0: Mpp::Credential, arg1: T::Hash[String, T.untyped]).returns(Mpp::Receipt)).void }
      def initialize(name, &verify_fn)
        @name = T.let(name, String)
        @verify_fn = T.let(verify_fn, T.proc.params(arg0: Mpp::Credential, arg1: T::Hash[String, T.untyped]).returns(Mpp::Receipt))
      end

      sig { params(credential: Mpp::Credential, request: T::Hash[String, T.untyped]).returns(Mpp::Receipt) }
      def verify(credential, request)
        @verify_fn.call(credential, request)
      end
    end

    # Decorator to define an intent from a block.
    #   intent = Mpp::Server.intent("charge") { |credential, request| ... }
    sig { params(name: String, blk: T.proc.params(arg0: Mpp::Credential, arg1: T::Hash[String, T.untyped]).returns(Mpp::Receipt)).returns(Mpp::Server::FunctionalIntent) }
    def self.intent(name, &blk)
      FunctionalIntent.new(name, &blk)
    end
  end
end
