# typed: strict
# frozen_string_literal: true

require "time"

module Mpp
  module Expires
    extend T::Sig

    module_function

    # Format a Time as ISO 8601 with Z suffix and millisecond precision.
    sig { params(time: Time).returns(String) }
    def to_iso(time)
      time.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    # Returns an ISO 8601 datetime string n seconds from now.
    sig { params(n: BasicObject).returns(T.untyped) }
    def seconds(n)
      to_iso(Time.now.utc + n)
    end

    # Returns an ISO 8601 datetime string n minutes from now.
    sig { params(n: Numeric).returns(String) }
    def minutes(n)
      to_iso(Time.now.utc + (n * 60))
    end

    # Returns an ISO 8601 datetime string n hours from now.
    sig { params(n: Numeric).returns(String) }
    def hours(n)
      to_iso(Time.now.utc + (n * 3600))
    end

    # Returns an ISO 8601 datetime string n days from now.
    sig { params(n: Numeric).returns(String) }
    def days(n)
      to_iso(Time.now.utc + (n * 86_400))
    end

    # Returns an ISO 8601 datetime string n weeks from now.
    sig { params(n: Numeric).returns(String) }
    def weeks(n)
      to_iso(Time.now.utc + (n * 7 * 86_400))
    end

    # Returns an ISO 8601 datetime string n months (30 days) from now.
    sig { params(n: Numeric).returns(String) }
    def months(n)
      to_iso(Time.now.utc + (n * 30 * 86_400))
    end

    # Returns an ISO 8601 datetime string n years (365 days) from now.
    sig { params(n: Numeric).returns(String) }
    def years(n)
      to_iso(Time.now.utc + (n * 365 * 86_400))
    end
  end
end
