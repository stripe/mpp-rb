# typed: strict
# frozen_string_literal: true

module Mpp
  module Extensions
    module MCP
      class PaymentRequiredError < StandardError
        extend T::Sig

        sig { returns(T.untyped) }
        attr_reader :challenges

        sig { returns(Integer) }
        attr_reader :code

        sig { params(challenges: T.untyped, message: BasicObject).void }
        def initialize(challenges:, message: "Payment Required")
          @challenges = T.let(challenges, T.untyped)
          @code = T.let(CODE_PAYMENT_REQUIRED, Integer)
          super(message)
        end

        sig { returns(T::Hash[T.untyped, T.untyped]) }
        def to_jsonrpc_error
          {
            "code" => CODE_PAYMENT_REQUIRED,
            "message" => message,
            "data" => {
              "httpStatus" => HTTP_STATUS_PAYMENT_REQUIRED,
              "challenges" => @challenges.map(&:to_dict)
            }
          }
        end
      end

      class PaymentVerificationError < StandardError
        extend T::Sig

        sig { returns(T.untyped) }
        attr_reader :challenges

        sig { returns(T.untyped) }
        attr_reader :reason

        sig { returns(T.untyped) }
        attr_reader :detail

        sig { returns(Integer) }
        attr_reader :code

        sig { params(challenges: T.untyped, reason: T.untyped, detail: T.untyped, message: BasicObject).void }
        def initialize(challenges:, reason: nil, detail: nil, message: "Payment Verification Failed")
          @challenges = T.let(challenges, T.untyped)
          @reason = T.let(reason, T.untyped)
          @detail = T.let(detail, T.untyped)
          @code = T.let(CODE_PAYMENT_VERIFICATION_FAILED, Integer)
          super(message)
        end

        sig { returns(T::Hash[T.untyped, T.untyped]) }
        def to_jsonrpc_error
          data = {
            "httpStatus" => HTTP_STATUS_PAYMENT_REQUIRED,
            "challenges" => @challenges.map(&:to_dict)
          }
          if @reason || @detail
            failure = {}
            failure["reason"] = @reason if @reason
            failure["detail"] = @detail if @detail
            data["failure"] = failure
          end
          {
            "code" => CODE_PAYMENT_VERIFICATION_FAILED,
            "message" => message,
            "data" => data
          }
        end
      end

      class MalformedCredentialError < StandardError
        extend T::Sig

        sig { returns(T.untyped) }
        attr_reader :detail

        sig { returns(Integer) }
        attr_reader :code

        sig { params(detail: T.untyped, message: BasicObject).void }
        def initialize(detail:, message: "Invalid params")
          @detail = T.let(detail, T.untyped)
          @code = T.let(CODE_MALFORMED_CREDENTIAL, Integer)
          super(message)
        end

        sig { returns(T::Hash[T.untyped, T.untyped]) }
        def to_jsonrpc_error
          {
            "code" => CODE_MALFORMED_CREDENTIAL,
            "message" => message,
            "data" => {
              "httpStatus" => HTTP_STATUS_PAYMENT_REQUIRED,
              "detail" => @detail
            }
          }
        end
      end
    end
  end
end
