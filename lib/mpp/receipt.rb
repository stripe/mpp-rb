# typed: true
# frozen_string_literal: true

module Mpp
  Receipt = Data.define(:status, :timestamp, :reference, :method, :external_id, :extra, :subscription_id, :extensions) do
    def initialize(status:, timestamp:, reference:, method: "", external_id: nil, extra: nil, subscription_id: nil, extensions: nil)
      super
    end

    # Parse a Receipt from a Payment-Receipt header value.
    def self.from_payment_receipt(header)
      Mpp::Parsing.parse_payment_receipt(header)
    end

    # Serialize to a Payment-Receipt header value.
    def to_payment_receipt
      Mpp::Parsing.format_payment_receipt(self)
    end

    # Create a success receipt with current timestamp.
    def self.success(reference, timestamp: nil, method: "tempo", external_id: nil, extra: nil, subscription_id: nil, extensions: nil)
      new(
        status: "success",
        timestamp: timestamp || Time.now.utc,
        reference: reference,
        method: method,
        external_id: external_id,
        subscription_id: subscription_id,
        extra: extra,
        extensions: extensions
      )
    end
  end
end
