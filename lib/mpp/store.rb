# typed: strict
# frozen_string_literal: true

module Mpp
  # In-memory key-value store for development/testing.
  # Production implementations should use Redis, DynamoDB, etc.
  #
  # Duck type interface (Store):
  #   get(key) -> value or nil
  #   put(key, value) -> void
  #   delete(key) -> void
  #   put_if_absent(key, value) -> bool
  class MemoryStore
    extend T::Sig

    sig { void }
    def initialize
      @data = T.let({}, T::Hash[T.untyped, T.untyped])
      @mutex = T.let(Mutex.new, Thread::Mutex)
    end

    sig { params(key: String).returns(T.untyped) }
    def get(key)
      @mutex.synchronize { @data[key] }
    end

    sig { params(key: String, value: T.untyped).returns(T.untyped) }
    def put(key, value)
      @mutex.synchronize { @data[key] = value }
    end

    sig { params(key: String).returns(T.untyped) }
    def delete(key)
      @mutex.synchronize { @data.delete(key) }
    end

    # Store value under key only if key does not already exist.
    # Returns true if the key was new, false if it already existed.
    sig { params(key: String, value: T.untyped).returns(T::Boolean) }
    def put_if_absent(key, value)
      @mutex.synchronize do
        return false if @data.key?(key)

        @data[key] = value
        true
      end
    end
  end
end
