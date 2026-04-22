# typed: strict

module Mpp
  class Receipt
    sig { returns(String) }
    def status; end

    sig { returns(Time) }
    def timestamp; end

    sig { returns(String) }
    def reference; end

    sig { returns(String) }
    def method; end

    sig { returns(T.nilable(String)) }
    def external_id; end

    sig { returns(T.nilable(T::Hash[String, T.untyped])) }
    def extra; end

    sig do
      params(
        status: String,
        timestamp: Time,
        reference: String,
        method: String,
        external_id: T.nilable(String),
        extra: T.nilable(T::Hash[String, T.untyped])
      ).void
    end
    def initialize(status:, timestamp:, reference:, method: "", external_id: nil, extra: nil); end

    sig { params(header: String).returns(Receipt) }
    def self.from_payment_receipt(header); end

    sig { returns(String) }
    def to_payment_receipt; end

    sig do
      params(
        reference: String,
        timestamp: T.nilable(Time),
        method: String,
        external_id: T.nilable(String)
      ).returns(Receipt)
    end
    def self.success(reference, timestamp: nil, method: "tempo", external_id: nil); end
  end
end
