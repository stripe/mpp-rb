# typed: strict
# frozen_string_literal: true

module Mpp
  module Methods
    module Tempo
      autoload :Defaults, "mpp/methods/tempo/defaults"
      autoload :Account, "mpp/methods/tempo/account"
      autoload :Keychain, "mpp/methods/tempo/keychain"
      autoload :Attribution, "mpp/methods/tempo/attribution"
      autoload :Rpc, "mpp/methods/tempo/rpc"
      autoload :Transaction, "mpp/methods/tempo/transaction"
      autoload :Schemas, "mpp/methods/tempo/schemas"
      # Eagerly require client_method so the Tempo.tempo factory method is available
      require_relative "tempo/client_method"
      autoload :Intents, "mpp/methods/tempo/intents"
      autoload :ChargeIntent, "mpp/methods/tempo/intents"
      autoload :FeePayer, "mpp/methods/tempo/fee_payer_envelope"
      autoload :Proof, "mpp/methods/tempo/proof"
    end
  end
end
