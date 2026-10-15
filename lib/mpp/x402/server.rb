# typed: true
# frozen_string_literal: true

require_relative "header"
require "digest"
require "openssl"

module Mpp
  module X402
    # Server-side x402 exact binding, challenge decoration, and header merge.
    module Server
      extend T::Sig

      module_function

      sig { params(values: T::Array[String]).returns(String) }
      def merge_payment_required(values)
        decoded = values.map { |value| Header.decode_payment_required(value) }
        first = decoded.first
        Kernel.raise ArgumentError, "Expected at least one x402 payment-required header." unless first

        rest = decoded.drop(1)
        incompatible = rest.any? do |value|
          value["resource"] != first["resource"] || value["extensions"] != first["extensions"]
        end
        if incompatible
          error = [first["error"], "Cannot merge x402 payment requirements with different resources."]
            .compact
            .reject { |item| item.to_s.empty? }
            .join("; ")
          return Header.encode_payment_required(first.merge("error" => error))
        end

        errors = [first["error"], *rest.map { |value| value["error"] }]
          .compact
          .reject { |item| item.to_s.empty? }
        merged = first.merge("accepts" => decoded.flat_map { |value| value["accepts"] })
        merged["error"] = errors.join("; ") unless errors.empty?
        Header.encode_payment_required(merged)
      end

      sig do
        params(
          request: T::Hash[T.untyped, T.untyped],
          authorization: T::Hash[T.untyped, T.untyped],
          max_timeout_seconds: Integer
        ).returns(T::Hash[String, T.untyped])
      end
      def to_payment_requirements(request, authorization:, max_timeout_seconds:)
        chain_id = request.dig("methodDetails", "chainId")
        Kernel.raise ArgumentError, "EVM charge request requires methodDetails.chainId" if chain_id.nil?

        {
          "amount" => request["amount"].to_s,
          "asset" => request["currency"].to_s,
          "extra" => {
            "assetTransferMethod" => ASSET_TRANSFER_EIP3009,
            "name" => authorization["name"] || authorization[:name],
            "version" => authorization["version"] || authorization[:version]
          },
          "maxTimeoutSeconds" => max_timeout_seconds,
          "network" => "#{EVM_NETWORK_PREFIX}#{chain_id}",
          "payTo" => request["recipient"].to_s,
          "scheme" => SCHEME_EXACT
        }
      end

      sig do
        params(
          requirements: T::Hash[T.untyped, T.untyped],
          resource_url: String,
          extensions: T.nilable(T::Hash[T.untyped, T.untyped]),
          error: T.nilable(String)
        ).returns(T::Hash[String, T.untyped])
      end
      def payment_required_body(requirements:, resource_url:, extensions: nil, error: nil)
        body = {
          "accepts" => [requirements],
          "resource" => {"url" => resource_url},
          "x402Version" => VERSION
        }
        body["extensions"] = extensions if extensions
        body["error"] = error if error
        body
      end

      sig do
        params(
          challenge: Mpp::Challenge,
          http_method: T.nilable(String)
        ).returns(T.nilable(T::Hash[String, T.untyped]))
      end
      def route_extensions(challenge, http_method)
        return nil if http_method.nil? || http_method.empty?

        binding = {"method" => http_method}
        binding["digest"] = challenge.digest if challenge.digest
        binding["opaque"] = Mpp::Parsing.b64_encode(challenge.opaque) if challenge.opaque
        {
          MPPX_EXTENSION_KEY => {
            "info" => binding,
            "schema" => MPPX_ROUTE_BINDING_SCHEMA
          }
        }
      end

      sig do
        params(
          accepted: T::Hash[T.untyped, T.untyped],
          resource: T::Hash[T.untyped, T.untyped],
          extensions: T::Hash[T.untyped, T.untyped]
        ).returns(String)
      end
      def route_nonce(accepted:, resource:, extensions:)
        input = [
          serialize_request(accepted),
          serialize_request(resource),
          serialize_request(extensions)
        ].join("|")
        digest = Digest::SHA256.digest(input)
        "0x#{digest.unpack1("H*")}"
      end

      sig { params(value: T.untyped).returns(String) }
      def serialize_request(value)
        json = Mpp::Json.compact_encode(value)
        Mpp.b64url_encode(json)
      end

      sig do
        params(
          payment_payload: T::Hash[T.untyped, T.untyped],
          requirements: T::Hash[T.untyped, T.untyped],
          resource_url: T.nilable(String),
          challenge: Mpp::Challenge,
          body: T.untyped,
          route_binding: Symbol,
          http_method: T.nilable(String)
        ).returns(T::Hash[T.untyped, T.untyped])
      end
      def bind_credential(payment_payload:, requirements:, resource_url:, challenge:, body:, route_binding:, http_method: nil)
        unless canonical_equal?(payment_payload["accepted"], requirements)
          Kernel.raise Mpp::VerificationFailedError.new(reason: "x402 payment payload does not match route requirements")
        end

        assert_body_digest!(challenge, body)

        if resource_url.nil? || resource_url.empty?
          Kernel.raise Mpp::VerificationFailedError.new(reason: "x402 route resource URL is required for binding")
        end
        if (route_binding == :required || challenge.digest || challenge.opaque) && (http_method.nil? || http_method.empty?)
          Kernel.raise Mpp::VerificationFailedError.new(reason: "x402 HTTP method is required for route binding")
        end

        expected_resource = {"url" => resource_url}
        payload_resource = payment_payload["resource"]
        unless payload_resource.is_a?(Hash) && payload_resource["url"] == resource_url
          Kernel.raise Mpp::VerificationFailedError.new(reason: "x402 payment payload resource does not match route resource")
        end

        # The x402 resource field is unsigned. Only the EIP-3009 nonce can bind
        # the authorization to this resource, even for a bodyless GET.
        extensions = payment_payload["extensions"]
        extension = extensions[MPPX_EXTENSION_KEY] if extensions.is_a?(Hash)
        info = extension["info"] if extension.is_a?(Hash)
        client_nonce = info["nonce"] if info.is_a?(Hash)
        unless client_nonce.is_a?(String) && !client_nonce.empty?
          reason = (route_binding == :required) ? "x402 payment payload does not bind required route metadata" : "x402 payment payload does not bind route resource"
          Kernel.raise Mpp::VerificationFailedError.new(reason: reason)
        end

        expected_extensions = route_extensions(challenge, http_method) || {}
        unless contains_extensions?(extensions, expected_extensions)
          Kernel.raise Mpp::VerificationFailedError.new(reason: "x402 payment payload extensions do not match route binding")
        end

        authorization = payload_to_authorization(payment_payload)
        expected_nonce = route_nonce(
          accepted: requirements,
          extensions: extensions,
          resource: expected_resource
        )
        unless authorization["nonce"].to_s.downcase == expected_nonce.downcase
          Kernel.raise Mpp::VerificationFailedError.new(reason: "x402 authorization nonce does not match route binding")
        end

        authorization
      end

      sig { params(payment_payload: T::Hash[T.untyped, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def payload_to_authorization(payment_payload)
        payload = payment_payload["payload"]
        unless payload.is_a?(Hash) && payload["authorization"].is_a?(Hash)
          Kernel.raise Mpp::VerificationFailedError.new(reason: "EVM charge only supports x402 EIP-3009 authorization payloads")
        end

        authorization = payload["authorization"]
        {
          "from" => authorization["from"].to_s,
          "nonce" => authorization["nonce"].to_s,
          "signature" => payload["signature"].to_s,
          "to" => authorization["to"].to_s,
          "type" => "authorization",
          "validAfter" => authorization["validAfter"].to_s,
          "validBefore" => authorization["validBefore"].to_s,
          "value" => authorization["value"].to_s
        }
      end

      sig { params(left: T.untyped, right: T.untyped).returns(T::Boolean) }
      def canonical_equal?(left, right)
        Mpp::Json.compact_encode(left) == Mpp::Json.compact_encode(right)
      end

      sig { params(challenge: Mpp::Challenge, body: T.untyped).void }
      def assert_body_digest!(challenge, body)
        return if body.nil? || challenge.digest.nil?
        return if Mpp::BodyDigest.verify(T.must(challenge.digest), body)

        Kernel.raise Mpp::VerificationFailedError.new(reason: "x402 payment body digest mismatch")
      end
      private_class_method :assert_body_digest!

      sig { params(actual: T.untyped, expected: T::Hash[T.untyped, T.untyped]).returns(T::Boolean) }
      def contains_extensions?(actual, expected)
        return false unless actual.is_a?(Hash)

        expected.all? do |key, expected_extension|
          actual_extension = actual[key]
          next false unless actual_extension.is_a?(Hash)

          canonical_equal?(actual_extension["schema"], expected_extension["schema"]) &&
            canonical_equal?(strip_client_nonce(actual_extension["info"]), expected_extension["info"])
        end
      end
      private_class_method :contains_extensions?

      sig { params(info: T.untyped).returns(T.untyped) }
      def strip_client_nonce(info)
        return info unless info.is_a?(Hash)

        info.except("nonce")
      end
      private_class_method :strip_client_nonce
    end
  end
end
