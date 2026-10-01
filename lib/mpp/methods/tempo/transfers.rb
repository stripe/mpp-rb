# typed: false
# frozen_string_literal: true

module Mpp
  module Methods
    module Tempo
      module Transfers
        MAX_SPLITS = 10
        HEX_PATTERN = /\A0x[a-fA-F0-9]+\z/
        MEMO_PATTERN = /\A0x[a-fA-F0-9]{64}\z/

        Transfer = Data.define(:amount, :recipient, :memo)

        module_function

        def resolve(amount:, recipient:, splits: nil, memo: nil)
          total_amount = Integer(amount)
          normalized_splits = normalize_splits(splits)
          if total_amount.zero? && normalized_splits.empty?
            return [Transfer.new(amount: 0, recipient: recipient, memo: memo)]
          end
          split_total = normalized_splits.sum(&:amount)
          if split_total >= total_amount
            raise ArgumentError, "Invalid charge request: split total must be less than total amount"
          end

          primary_amount = total_amount - split_total
          if primary_amount <= 0
            raise ArgumentError, "Invalid charge request: primary transfer amount must be positive"
          end

          [Transfer.new(amount: primary_amount, recipient: recipient, memo: memo), *normalized_splits]
        end

        def normalize_splits(splits)
          return [] if splits.nil?
          unless splits.is_a?(Array) && splits.length.between?(1, MAX_SPLITS)
            raise ArgumentError, "Invalid charge request: splits must contain between 1 and #{MAX_SPLITS} entries"
          end

          splits.map do |split|
            amount = Integer(field(split, :amount))
            raise ArgumentError, "Invalid charge request: split amount must be positive" unless amount.positive?
            recipient = field(split, :recipient)
            unless recipient.is_a?(String) && recipient.match?(HEX_PATTERN)
              raise ArgumentError, "Invalid charge request: split recipient must be a hex address"
            end
            memo = field(split, :memo)
            if !memo.nil? && !(memo.is_a?(String) && memo.match?(MEMO_PATTERN))
              raise ArgumentError, "Invalid charge request: split memo must be 32 bytes"
            end

            Transfer.new(
              amount: amount,
              recipient: recipient,
              memo: memo
            )
          end
        end
        private_class_method :normalize_splits

        def field(value, name)
          return value.public_send(name) if value.respond_to?(name)
          raise ArgumentError, "Invalid charge request: split must be an object" unless value.respond_to?(:[])

          value[name.to_s] || value[name]
        end
        private_class_method :field
      end
    end
  end
end
