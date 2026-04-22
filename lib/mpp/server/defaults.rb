# typed: strict
# frozen_string_literal: true

module Mpp
  module Server
    module Defaults
      extend T::Sig

      SECRET_KEY_NAME = "MPP_SECRET_KEY"

      REALM_ENV_VARS = %w[
        MPP_REALM
        FLY_APP_NAME
        HEROKU_APP_NAME
        HOST
        HOSTNAME
        RAILWAY_PUBLIC_DOMAIN
        RENDER_EXTERNAL_HOSTNAME
        VERCEL_URL
        WEBSITE_HOSTNAME
      ].freeze

      module_function

      # Detect server realm from environment.
      sig { returns(String) }
      def detect_realm
        REALM_ENV_VARS.each do |var|
          value = ENV.fetch(var, nil)
          return value if value && !value.empty?
        end
        "localhost"
      end

      # Get server secret key from environment.
      sig { returns(String) }
      def detect_secret_key
        value = ENV.fetch(SECRET_KEY_NAME, nil)
        return value if value && !value.strip.empty?

        Kernel.raise ArgumentError, "Missing secret key. Set MPP_SECRET_KEY or pass secret_key explicitly."
      end
    end
  end
end
