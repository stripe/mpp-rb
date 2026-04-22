# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "mpp/version"
require_relative "mpp/json"
require_relative "mpp/challenge_id"
require_relative "mpp/secure_compare"

module Mpp
  extend T::Sig

  autoload :Challenge, "mpp/challenge"
  autoload :ChallengeEcho, "mpp/challenge_echo"
  autoload :Credential, "mpp/credential"
  autoload :Receipt, "mpp/receipt"
  autoload :Parsing, "mpp/parsing"
  autoload :Json, "mpp/json"
  autoload :BodyDigest, "mpp/body_digest"
  autoload :Expires, "mpp/expires"
  autoload :Units, "mpp/units"
  autoload :MemoryStore, "mpp/store"

  # Server module (autoloaded)
  autoload :Server, "mpp/server"

  # Client module (autoloaded)
  autoload :Client, "mpp/client"

  # Methods namespace
  module Methods
    autoload :Tempo, "mpp/methods/tempo"
    autoload :Stripe, "mpp/methods/stripe"
  end

  # Extensions namespace
  module Extensions
    autoload :MCP, "mpp/extensions/mcp"
  end

  sig { params(method: T.untyped, realm: T.untyped, secret_key: T.untyped).returns(T.untyped) }
  def self.create(method:, realm: nil, secret_key: nil)
    Server::MppHandler.create(method: method, realm: realm, secret_key: secret_key)
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
  autoload :ParseError, "mpp/errors"
  autoload :InsufficientBalanceError, "mpp/errors"
  autoload :InvalidSignatureError, "mpp/errors"
  autoload :SignerMismatchError, "mpp/errors"
  autoload :AmountExceedsDepositError, "mpp/errors"
  autoload :DeltaTooSmallError, "mpp/errors"
  autoload :ChannelNotFoundError, "mpp/errors"
  autoload :ChannelClosedError, "mpp/errors"
end
