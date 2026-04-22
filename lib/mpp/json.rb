# typed: strict
# frozen_string_literal: true

require "json"

module Mpp
  module Json
    extend T::Sig

    module_function

    # Encode object as compact JSON with recursively sorted keys.
    # Matches Python's json.dumps(separators=(",", ":"), sort_keys=True).
    sig { params(obj: T.untyped).returns(String) }
    def compact_encode(obj)
      ::JSON.generate(deep_sort_keys(obj), space: "", object_nl: "", array_nl: "")
    end

    # Recursively sort hash keys for deterministic serialization.
    sig { params(obj: T.anything).returns(T.untyped) }
    def deep_sort_keys(obj)
      case obj
      when Hash
        obj.sort_by { |k, _| k.to_s }.to_h.transform_values { |v| deep_sort_keys(v) }
      when Array
        obj.map { |v| deep_sort_keys(v) }
      else
        obj
      end
    end
  end
end
