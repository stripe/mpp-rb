# typed: strict
# frozen_string_literal: true

module Mpp
  module Server
    autoload :Defaults, "mpp/server/defaults"
    autoload :Intent, "mpp/server/intent"
    autoload :FunctionalIntent, "mpp/server/intent"
    autoload :Method, "mpp/server/method"
    autoload :Verify, "mpp/server/verify"
    autoload :MppHandler, "mpp/server/mpp_handler"
    autoload :Decorator, "mpp/server/decorator"
    autoload :Middleware, "mpp/server/middleware"
  end
end
