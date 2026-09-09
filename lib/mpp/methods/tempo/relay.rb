# typed: false
# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "time"
require "uri"
require_relative "../../http/headers"
require_relative "attribution"

module Mpp
  module Methods
    module Tempo
      # HTTP client for a Tempo API-compatible MPP relay.
      #
      # `resolve` accepts:
      #   * a URL string (unauthenticated relay)
      #   * a config hash (`url:` plus optional `headers:`, or mppx-style
      #     `api_base_url:` / `api_key:`)
      #   * any object that responds to `#validate` and `#broadcast`
      class Relay
        DEFAULT_API_BASE_URL = "https://api.tempo.xyz"
        VALIDATE_PATH = "/v1/mpp/validate"
        BROADCAST_PATH = "/v1/mpp/broadcast"
        DEFAULT_TIMEOUT = Rpc::DEFAULT_TIMEOUT

        ERROR_CODES = %w[
          already_used
          broadcast_failed
          expired
          invalid_payment
          insufficient_funds
          policy_denied
          screen_rejected
          simulation_failed
          temporarily_unavailable
          unsupported
          unknown
        ].freeze

        attr_reader :base_url

        def initialize(url, headers: nil)
          @base_url = Mpp::Http::Headers.normalize_base_url(url)
          raise ArgumentError, "relay url is required" if @base_url.empty?

          @headers = headers
        end

        def self.resolve_optional(relay)
          return if relay.nil? || relay == false

          resolve(relay)
        end

        def self.resolve(relay)
          return relay if relay.is_a?(Relay)
          return new(relay) if relay.is_a?(String) && !relay.empty?
          return from_config(relay) if relay.is_a?(Hash)
          return relay if duck_type?(relay)

          raise ArgumentError, "relay must be a URL, {url:, headers:}, or an object that implements #validate and #broadcast"
        end

        def self.from_config(config)
          cfg = Mpp::Http::Headers.symbolize(config)
          url = cfg[:url] || cfg[:api_base_url] || cfg[:apiBaseUrl] || cfg[:base_url] || cfg[:baseUrl]
          url = DEFAULT_API_BASE_URL if url.nil? || url.to_s.empty?
          headers = merge_api_key_headers(cfg[:headers], cfg[:api_key] || cfg[:apiKey])
          new(url.to_s, headers: headers)
        end

        def self.duck_type?(relay)
          !relay.nil? && relay.respond_to?(:validate) && relay.respond_to?(:broadcast)
        end

        def self.merge_api_key_headers(headers, api_key)
          return headers if api_key.nil? || api_key.to_s.empty?

          defaults = {"tempo-api-key" => api_key.to_s}
          return defaults if headers.nil?

          if headers.respond_to?(:call)
            original = headers
            ->(path) {
              extra = (original.arity == 0) ? original.call : original.call(path)
              extra = {} unless extra.is_a?(Hash)
              defaults.merge(Mpp::Http::Headers.stringify(extra))
            }
          elsif headers.is_a?(Hash)
            defaults.merge(Mpp::Http::Headers.stringify(headers))
          else
            defaults
          end
        end
        private_class_method :merge_api_key_headers

        def verify(credential, _request = nil)
          input = to_relay_input(credential)
          validate(input)
          broadcast(input)
        end

        def validate(input)
          response = post(VALIDATE_PATH, input)
          raise failure(response) unless success?(response)

          true
        end

        def broadcast(input)
          response = post(BROADCAST_PATH, input, extra_headers: {
            "Idempotency-Key" => idempotency_key(input)
          })
          raise failure(response) unless broadcast_success?(response)

          to_receipt(response.fetch("receipt"))
        end

        private

        def post(path, input, extra_headers: {})
          uri = URI.parse("#{@base_url}#{path}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.read_timeout = DEFAULT_TIMEOUT

          request = Net::HTTP::Post.new(uri)
          request["Accept"] = "application/json"
          request["Content-Type"] = "application/json"
          Mpp::Http::Headers.resolve(@headers, path).each { |key, value| request[key] = value }
          extra_headers.each { |key, value| request[key] = value }
          request.body = JSON.generate(input)

          response = http.request(request)
          unless response.is_a?(Net::HTTPSuccess)
            raise Mpp::VerificationFailedError.new(reason: "relay #{path} returned HTTP #{response.code}")
          end

          body = response.body.to_s
          if body.empty?
            raise Mpp::VerificationFailedError.new(reason: "relay #{path} returned an empty body")
          end

          parsed = JSON.parse(body)
          unless parsed.is_a?(Hash)
            raise Mpp::VerificationFailedError.new(reason: "relay #{path} returned JSON that is not an object")
          end

          parsed
        rescue JSON::ParserError
          raise Mpp::VerificationFailedError.new(reason: "relay #{path} returned invalid JSON")
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Net::OpenTimeout, Net::ReadTimeout, SocketError => e
          raise Mpp::VerificationFailedError.new(reason: "relay request failed: #{e.message}")
        end

        def to_relay_input(credential)
          echo = credential.challenge
          challenge = {
            "id" => echo.id,
            "realm" => echo.realm,
            "method" => echo.method,
            "intent" => echo.intent,
            "request" => decode_request(echo.request)
          }
          challenge["expires"] = echo.expires if echo.expires
          challenge["digest"] = echo.digest if echo.digest
          challenge["opaque"] = echo.opaque if echo.opaque

          input = {
            "challenge" => challenge,
            "payload" => credential.payload
          }
          input["source"] = credential.source if credential.source
          input
        end

        def decode_request(request)
          return request if request.is_a?(Hash)
          return request unless request.is_a?(String) && !request.empty?

          Mpp::Parsing.b64_decode(request)
        rescue Mpp::ParseError
          request
        end

        def idempotency_key(input)
          payload = input["payload"]
          if payload.is_a?(Hash) && payload["type"] == "transaction" && payload["signature"].is_a?(String)
            hex = payload["signature"].delete_prefix("0x")
            if hex.match?(/\A[0-9a-fA-F]+\z/) && hex.length.even?
              hash = Attribution.keccak256([hex].pack("H*"))
              return "mpp_0x#{hash.unpack1("H*")}"
            end
          end

          digest = Digest::SHA256.hexdigest(Mpp::Json.compact_encode(input))
          "mpp_0x#{digest}"
        end

        def success?(response)
          response.is_a?(Hash) && response["success"] == true
        end

        def broadcast_success?(response)
          success?(response) && relay_receipt?(response["receipt"])
        end

        def relay_receipt?(value)
          value.is_a?(Hash) &&
            value["method"].is_a?(String) &&
            value["reference"].is_a?(String) &&
            value["timestamp"].is_a?(String) &&
            (value["externalId"].nil? || value["externalId"].is_a?(String))
        end

        def to_receipt(receipt)
          timestamp = begin
            Time.iso8601(receipt["timestamp"].to_s.gsub("Z", "+00:00"))
          rescue ArgumentError
            raise failure
          end

          Mpp::Receipt.success(
            receipt["reference"],
            timestamp: timestamp,
            method: receipt["method"],
            external_id: receipt["externalId"]
          )
        end

        def failure(response = nil)
          code = relay_error_code(response)
          return Mpp::PaymentExpiredError.new if code == "expired"

          reason = case code
          when "already_used", "broadcast_failed", "insufficient_funds", "invalid_payment",
            "simulation_failed", "unsupported", "temporarily_unavailable"
            code.tr("_", " ")
          end
          Mpp::VerificationFailedError.new(reason: reason)
        end

        def relay_error_code(value)
          return unless value.is_a?(Hash)

          error = value["error"]
          return unless error.is_a?(Hash)

          code = error["code"]
          code if ERROR_CODES.include?(code)
        end
      end
    end
  end
end
