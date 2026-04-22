# frozen_string_literal: true

require_relative "lib/mpp/version"

Gem::Specification.new do |spec|
  spec.name = "mpp-rb"
  spec.version = Mpp::VERSION
  spec.authors = ["Stripe"]
  spec.summary = "HTTP 402 Payment Authentication for Ruby"
  spec.description = "Ruby SDK for the Machine Payments Protocol (MPP) — an HTTP 402 Payment Authentication scheme."
  spec.homepage = "https://github.com/stripe/mpp-rb"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"

  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "base64"

  # All runtime deps are stdlib (openssl, base64, json, bigdecimal, time, uri)
  # Optional deps are autoloaded:
  #   async, async-http  — client + Tempo RPC
  #   eth                — Tempo account signing
  #   rlp                — fee payer envelope

  spec.metadata["rubygems_mfa_required"] = "true"
end
