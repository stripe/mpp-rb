# typed: false
# frozen_string_literal: true

module Mpp
  ChallengeEcho = Data.define(
    :id,
    :realm,
    :method,
    :intent,
    :request,
    :expires,
    :digest,
    :opaque
  ) do
    def initialize(id:, realm:, method:, intent:, request:, expires: nil, digest: nil, opaque: nil)
      super
    end
  end
end
