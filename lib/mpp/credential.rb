# typed: true
# frozen_string_literal: true

module Mpp
  Credential = Data.define(:challenge, :payload, :source) do
    def initialize(challenge:, payload:, source: nil)
      super
    end

    # Parse a Credential from an Authorization header value.
    def self.from_authorization(header)
      Mpp::Parsing.parse_authorization(header)
    end

    # Serialize to an Authorization header value.
    def to_authorization
      Mpp::Parsing.format_authorization(self)
    end
  end
end
