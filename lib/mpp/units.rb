# typed: strict
# frozen_string_literal: true

require "bigdecimal"

module Mpp
  module Units
    extend T::Sig

    module_function

    # Convert a human-readable decimal string to base units.
    # e.g. parse_units("1.5", 6) => 1500000
    sig { params(value: T.untyped, decimals: T.any(Integer, Float, Rational, BigDecimal)).returns(Integer) }
    def parse_units(value, decimals)
      Kernel.raise ArgumentError, "amount is required" unless value.is_a?(String) && !value.strip.empty?

      stripped = value.strip
      d = Kernel.BigDecimal(stripped)
    rescue ArgumentError
      Kernel.raise ArgumentError, "Invalid amount: #{value.inspect}"
    else
      Kernel.raise ArgumentError, "amount must be finite" unless d.finite?
      Kernel.raise ArgumentError, "amount must be non-negative" if d.negative?

      result = d * (Kernel.BigDecimal(10)**decimals)
      int_result = result.to_i

      unless T.unsafe(result) == int_result
        Kernel.raise ArgumentError,
          "Amount #{value.inspect} with #{decimals} decimals produces fractional base units"
      end

      int_result
    end

    # Transform request amounts from human-readable to base units.
    # If `decimals` is present, converts amount and optional suggestedDeposit.
    sig { params(request: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
    def transform_units(request)
      return request unless request.key?("decimals")

      result = request.dup
      decimals = result.delete("decimals")

      Kernel.raise ArgumentError, "decimals must be an integer, got #{decimals.class.name}" unless decimals.is_a?(Integer)

      result["amount"] = parse_units(result["amount"], decimals).to_s if result.key?("amount")

      if result.key?("suggestedDeposit") && !result["suggestedDeposit"].nil?
        result["suggestedDeposit"] = parse_units(result["suggestedDeposit"], decimals).to_s
      end

      result
    end
  end
end
