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

      sig { params(methods: T::Array[T.untyped], events: T.nilable(Mpp::Events::Dispatcher)).void }
      def initialize(methods:, events: nil)
        @methods = T.let(methods.to_h { |m| [m.name, m] }, T::Hash[String, T.untyped])
        @events = T.let(events || Mpp::Events.client_dispatcher, Mpp::Events::Dispatcher)
      end

      sig { params(name: String, handler: T.nilable(T.untyped), block: T.nilable(T.proc.params(payload: T.untyped).returns(T.untyped))).returns(T.proc.void) }
      def on(name, handler = nil, &block)
        @events.on(name, handler, &block)
      end

      sig { params(handler: T.nilable(T.untyped), block: T.nilable(T.proc.params(payload: T.untyped).returns(T.untyped))).returns(T.proc.void) }
      def on_challenge_received(handler = nil, &block)
        on(Mpp::Events::CHALLENGE_RECEIVED, handler, &block)
      end

      sig { params(handler: T.nilable(T.untyped), block: T.nilable(T.proc.params(payload: T.untyped).returns(T.untyped))).returns(T.proc.void) }
      def on_credential_created(handler = nil, &block)
        on(Mpp::Events::CREDENTIAL_CREATED, handler, &block)
      end

      sig { params(handler: T.nilable(T.untyped), block: T.nilable(T.proc.params(payload: T.untyped).returns(T.untyped))).returns(T.proc.void) }
      def on_payment_failed(handler = nil, &block)
        on(Mpp::Events::PAYMENT_FAILED, handler, &block)
      end

      sig { params(handler: T.nilable(T.untyped), block: T.nilable(T.proc.params(payload: T.untyped).returns(T.untyped))).returns(T.proc.void) }
      def on_payment_response(handler = nil, &block)
        on(Mpp::Events::PAYMENT_RESPONSE, handler, &block)
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
        challenge, matched_method = find_matching_challenge(www_auth_headers, input: url, response: response)
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

        auth_header = nil
        create_credential = Kernel.lambda do
          auth_header ||= credential_authorization(matched_method.create_credential(challenge))
        end

        begin
          event_credential = nil
          if @events.has_handlers?(Mpp::Events::CHALLENGE_RECEIVED)
            # challenge.received can override credential creation; first non-empty credential wins.
            event_credential = @events.emit_first(Mpp::Events::CHALLENGE_RECEIVED, {
              challenge: challenge,
              challenges: [challenge],
              create_credential: create_credential,
              input: url,
              method: matched_method,
              response: response
            })
          end
          auth_header = credential_authorization(event_credential) unless event_credential.nil?
          auth_header ||= create_credential.call

          if @events.has_handlers?(Mpp::Events::CREDENTIAL_CREATED)
            @events.emit(Mpp::Events::CREDENTIAL_CREATED, {
              challenge: challenge,
              credential: auth_header,
              input: url,
              method: matched_method,
              response: response
            })
          end
        rescue => e
          if @events.has_handlers?(Mpp::Events::PAYMENT_FAILED)
            @events.emit(Mpp::Events::PAYMENT_FAILED, {
              challenge: challenge,
              challenges: [challenge],
              error: e,
              input: url,
              method: matched_method,
              response: response
            })
          end
          raise
        end

        retry_headers = headers.merge("Authorization" => auth_header)
        payment_response = nil
        begin
          payment_response = send_request(uri, method, retry_headers, body)
        rescue => e
          if @events.has_handlers?(Mpp::Events::PAYMENT_FAILED)
            @events.emit(Mpp::Events::PAYMENT_FAILED, {
              challenge: challenge,
              challenges: [challenge],
              credential: auth_header,
              error: e,
              input: url,
              method: matched_method,
              response: response
            })
          end
          raise
        end

        if payment_response.code.to_i.between?(200, 299) && @events.has_handlers?(Mpp::Events::PAYMENT_RESPONSE)
          @events.emit(Mpp::Events::PAYMENT_RESPONSE, {
            challenge: challenge,
            credential: auth_header,
            input: url,
            method: matched_method,
            response: payment_response
          })
        elsif @events.has_handlers?(Mpp::Events::PAYMENT_FAILED)
          @events.emit(Mpp::Events::PAYMENT_FAILED, {
            challenge: challenge,
            challenges: [challenge],
            credential: auth_header,
            error: Mpp::VerificationFailedError.new(reason: "retry returned HTTP #{payment_response.code}"),
            input: url,
            method: matched_method,
            response: payment_response
          })
        end

        payment_response
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

      sig { params(www_auth_headers: T.untyped, input: T.untyped, response: T.untyped).returns(T::Array[T.untyped]) }
      def find_matching_challenge(www_auth_headers, input: nil, response: nil)
        www_auth_headers.each do |header|
          next unless header.downcase.start_with?("payment ")

          begin
            parsed = Mpp::Challenge.from_www_authenticate(header)
            return [parsed, @methods[parsed.method]] if @methods.key?(parsed.method)
          rescue Mpp::ParseError => e
            if @events.has_handlers?(Mpp::Events::PAYMENT_FAILED)
              @events.emit(Mpp::Events::PAYMENT_FAILED, {
                error: e,
                input: input,
                response: response
              })
            end
            next
          end
        end
        [nil, nil]
      end

      sig { params(credential: T.untyped).returns(String) }
      def credential_authorization(credential)
        auth_header = if credential.respond_to?(:to_authorization)
          credential.to_authorization
        elsif credential.is_a?(String)
          credential
        else
          raise ArgumentError, "Credential must be a String or respond to #to_authorization"
        end

        validate_authorization_header(auth_header)
        auth_header
      end

      sig { params(auth_header: String).void }
      def validate_authorization_header(auth_header)
        unless auth_header.start_with?("Payment ") && auth_header.length > 8
          raise ArgumentError, "Credential must be a non-empty Payment authorization header"
        end

        raise ArgumentError, "Credential contains invalid header characters" if auth_header.match?(/[[:cntrl:]]/)
      end
    end

    # Module-level convenience methods
    extend T::Sig

    module_function

    sig { params(method: T.untyped, url: T.untyped, methods: T::Array[T.untyped], events: T.nilable(Mpp::Events::Dispatcher), kwargs: T.untyped).returns(T.untyped) }
    def request(method, url, methods:, events: nil, **kwargs)
      transport = Transport.new(methods: methods, events: events)
      transport.request(method, url, **kwargs)
    end

    sig { params(url: T.untyped, methods: T::Array[T.untyped], events: T.nilable(Mpp::Events::Dispatcher), kwargs: T.untyped).returns(T.untyped) }
    def get(url, methods:, events: nil, **kwargs)
      request("GET", url, **T.unsafe({methods: methods, events: events, **kwargs}))
    end

    sig { params(url: T.untyped, methods: T::Array[T.untyped], events: T.nilable(Mpp::Events::Dispatcher), kwargs: T.untyped).returns(T.untyped) }
    def post(url, methods:, events: nil, **kwargs)
      request("POST", url, **T.unsafe({methods: methods, events: events, **kwargs}))
    end
  end
end
