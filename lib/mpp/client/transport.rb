# typed: strict
# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "time"

module Mpp
  module Client
    # Payment-aware HTTP client that handles 402 Payment Required responses.
    #
    # Wraps Net::HTTP and automatically:
    # 1. Detects 402 responses with WWW-Authenticate: Payment headers
    # 2. Parses the challenge and finds a matching payment method
    # 3. Creates credentials and retries the request
    # 4. Returns the final response
    class Transport
      extend T::Sig

      sig { params(methods: T::Array[T.untyped]).void }
      def initialize(methods:)
        @methods = T.let(methods.to_h { |m| [m.name, m] }, T::Hash[String, T.untyped])
      end

      # Send an HTTP request with automatic 402 payment handling.
      # Returns [Net::HTTPResponse, body_string].
      sig { params(method: T.untyped, url: T.any(URI::Generic, String), headers: T.untyped, body: T.untyped).returns(T.untyped) }
      def request(method, url, headers: {}, body: nil)
        uri = URI(url)
        response = send_request(uri, method, headers, body)

        return response unless response.code.to_i == 402

        # Parse WWW-Authenticate headers
        www_auth_headers = response.get_fields("www-authenticate") || []
        challenge, matched_method = find_matching_challenge(www_auth_headers)
        return response unless challenge && matched_method

        # Check expiry before paying (client-side guardrail)
        if challenge.expires
          begin
            expires_dt = Time.iso8601(challenge.expires.gsub("Z", "+00:00"))
            return response if expires_dt < Time.now.utc
          rescue ArgumentError
            # If we can't parse, let server validate
          end
        end

        credential = matched_method.create_credential(challenge)
        auth_header = credential.to_authorization

        retry_headers = headers.merge("Authorization" => auth_header)
        send_request(uri, method, retry_headers, body)
      end

      sig { params(url: T.any(URI::Generic, String), kwargs: T.untyped).returns(T.untyped) }
      def get(url, **kwargs)
        request("GET", url, **kwargs)
      end

      sig { params(url: T.any(URI::Generic, String), kwargs: T.untyped).returns(T.untyped) }
      def post(url, **kwargs)
        request("POST", url, **kwargs)
      end

      sig { params(url: T.any(URI::Generic, String), kwargs: T.untyped).returns(T.untyped) }
      def put(url, **kwargs)
        request("PUT", url, **kwargs)
      end

      sig { params(url: T.any(URI::Generic, String), kwargs: T.untyped).returns(T.untyped) }
      def delete(url, **kwargs)
        request("DELETE", url, **kwargs)
      end

      private

      sig { params(uri: URI::Generic, method: T.untyped, headers: T::Hash[String, String], body: T.nilable(String)).returns(Net::HTTPResponse) }
      def send_request(uri, method, headers, body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"

        request_class = case method.to_s.upcase
        when "GET" then Net::HTTP::Get
        when "POST" then Net::HTTP::Post
        when "PUT" then Net::HTTP::Put
        when "DELETE" then Net::HTTP::Delete
        when "PATCH" then Net::HTTP::Patch
        else raise ArgumentError, "Unsupported HTTP method: #{method}"
        end

        req = request_class.new(uri)
        headers.each { |k, v| req[k] = v }
        req.body = body if body

        http.request(req)
      end

      sig { params(www_auth_headers: T.untyped).returns(T::Array[T.untyped]) }
      def find_matching_challenge(www_auth_headers)
        www_auth_headers.each do |header|
          next unless header.downcase.start_with?("payment ")

          begin
            parsed = Mpp::Challenge.from_www_authenticate(header)
            return [parsed, @methods[parsed.method]] if @methods.key?(parsed.method)
          rescue Mpp::ParseError
            next
          end
        end
        [nil, nil]
      end
    end

    # Module-level convenience methods
    extend T::Sig

    module_function

    sig { params(method: T.untyped, url: T.untyped, methods: T::Array[T.untyped], kwargs: T.untyped).returns(T.untyped) }
    def request(method, url, methods:, **kwargs)
      transport = Transport.new(methods: methods)
      transport.request(method, url, **kwargs)
    end

    sig { params(url: T.untyped, methods: T::Array[T.untyped], kwargs: T.untyped).returns(T.untyped) }
    def get(url, methods:, **kwargs)
      request("GET", url, **T.unsafe({methods: methods, **kwargs}))
    end

    sig { params(url: T.untyped, methods: T::Array[T.untyped], kwargs: T.untyped).returns(T.untyped) }
    def post(url, methods:, **kwargs)
      request("POST", url, **T.unsafe({methods: methods, **kwargs}))
    end
  end
end
