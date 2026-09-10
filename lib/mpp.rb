# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "mpp/version"
require_relative "mpp/json"
require_relative "mpp/challenge_id"
require_relative "mpp/secure_compare"

module Mpp
  extend T::Sig

  AUTHORIZATION_HEADER = T.let("Authorization", String)
  PAYMENT_AUTHORIZATION_HEADER = T.let("Payment-Authorization", String)

  autoload :Challenge, "mpp/challenge"
  autoload :ChallengeEcho, "mpp/challenge_echo"
  autoload :Credential, "mpp/credential"
  autoload :Receipt, "mpp/receipt"
  autoload :Validation, "mpp/validation"
  autoload :Parsing, "mpp/parsing"
  autoload :Json, "mpp/json"
  autoload :BodyDigest, "mpp/body_digest"
  autoload :Expires, "mpp/expires"
  autoload :Events, "mpp/events"
  autoload :Units, "mpp/units"
  autoload :MemoryStore, "mpp/store"
  autoload :Http, "mpp/http"
  autoload :X402, "mpp/x402"

  # Server module (autoloaded)
  autoload :Server, "mpp/server"

  # Client module (autoloaded)
  autoload :Client, "mpp/client"

  # Methods namespace
  module Methods
    autoload :Tempo, "mpp/methods/tempo"
    autoload :Stripe, "mpp/methods/stripe"
    autoload :Evm, "mpp/methods/evm"
  end

  # Extensions namespace
  module Extensions
    autoload :MCP, "mpp/extensions/mcp"
  end

  sig { params(method: T.untyped, methods: T.nilable(T::Array[T.untyped]), realm: T.untyped, secret_key: T.untyped, events: T.nilable(Mpp::Events::Dispatcher), requires_auth: T::Boolean).returns(T.untyped) }
  def self.create(method: nil, methods: nil, realm: nil, secret_key: nil, events: nil, requires_auth: false)
    Server::MppHandler.create(
      method: method,
      methods: methods,
      realm: realm,
      secret_key: secret_key,
      events: events,
      requires_auth: requires_auth
    )
  end

  # Error hierarchy
  autoload :PaymentError, "mpp/errors"
  autoload :PaymentRequiredError, "mpp/errors"
  autoload :MalformedCredentialError, "mpp/errors"
  autoload :InvalidChallengeError, "mpp/errors"
  autoload :VerificationFailedError, "mpp/errors"
  autoload :PaymentExpiredError, "mpp/errors"
  autoload :InvalidPayloadError, "mpp/errors"
  autoload :PaymentInsufficientError, "mpp/errors"
  autoload :PaymentMethodUnsupportedError, "mpp/errors"
  autoload :PaymentActionRequiredError, "mpp/errors"
  autoload :BadRequestError, "mpp/errors"
  autoload :VerificationError, "mpp/errors"
  autoload :TransactionPendingError, "mpp/errors"
  autoload :ParseError, "mpp/errors"
  autoload :InsufficientBalanceError, "mpp/errors"
  autoload :InvalidSignatureError, "mpp/errors"
  autoload :SignerMismatchError, "mpp/errors"
  autoload :AmountExceedsDepositError, "mpp/errors"
  autoload :DeltaTooSmallError, "mpp/errors"
  autoload :ChannelNotFoundError, "mpp/errors"
  autoload :ChannelClosedError, "mpp/errors"
end
