# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Tempo
      # Resolves the RLP codec used by Tempo transactions. The default adapter
      # loads the optional rlp gem only when encoding or decoding is requested.
      module Rlp
        module DefaultCodec
          module_function

          def encode(value)
            require_rlp!
            RLP.encode(value)
          end

          def decode(bytes)
            require_rlp!
            RLP.decode(bytes)
          end

          def require_rlp!
            Kernel.require "rlp"
          rescue LoadError
            raise LoadError, "rlp gem is required for Tempo transaction encoding. Install with: gem install rlp"
          end
          private_class_method :require_rlp!
        end

        module_function

        def resolve(codec = nil)
          codec ||= DefaultCodec
          unless codec.respond_to?(:encode) && codec.respond_to?(:decode)
            raise ArgumentError, "rlp provider must respond to encode and decode"
          end

          codec
        end
      end
    end
  end
end
