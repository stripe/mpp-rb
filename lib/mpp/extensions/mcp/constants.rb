# typed: strict
# frozen_string_literal: true

module Mpp
  module Extensions
    module MCP
      META_CREDENTIAL = "org.paymentauth/credential"
      META_RECEIPT = "org.paymentauth/receipt"

      CODE_PAYMENT_REQUIRED = -32_042
      CODE_PAYMENT_VERIFICATION_FAILED = -32_043
      CODE_MALFORMED_CREDENTIAL = -32_602

      HTTP_STATUS_PAYMENT_REQUIRED = 402
    end
  end
end
