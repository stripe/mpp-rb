# typed: true
# frozen_string_literal: true

require "base64"
require "json"
require "time"

module Mpp
  module Extensions
    module MCP
      MCPChallenge = Data.define(:id, :realm, :method, :intent, :request,
        :expires, :description, :digest, :opaque) do
        def initialize(id:, realm:, method:, intent:, request:,
          expires: nil, description: nil, digest: nil, opaque: nil)
          super
        end

        def to_dict
          result = {
            "id" => id,
            "realm" => realm,
            "method" => method,
            "intent" => intent,
            "request" => request
          }
          result["expires"] = expires if expires
          result["description"] = description if description
          result["digest"] = digest if digest
          result["opaque"] = opaque if opaque
          result
        end

        def self.from_dict(data)
          new(
            id: data["id"],
            realm: data["realm"],
            method: data["method"],
            intent: data["intent"],
            request: data["request"],
            expires: data["expires"],
            description: data["description"],
            digest: data["digest"],
            opaque: data["opaque"]
          )
        end

        def to_core
          Mpp::Challenge.new(
            id: id,
            method: method,
            intent: intent,
            request: request,
            digest: digest,
            opaque: opaque
          )
        end

        def self.from_core(challenge, realm, expires: nil, description: nil)
          new(
            id: challenge.id,
            realm: realm,
            method: challenge.method,
            intent: challenge.intent,
            request: challenge.request,
            expires: expires,
            description: description,
            digest: challenge.digest,
            opaque: challenge.opaque
          )
        end
      end

      MCPCredential = Data.define(:challenge, :payload, :source) do
        def initialize(challenge:, payload:, source: nil)
          super
        end

        def to_dict
          result = {
            "challenge" => challenge.to_dict,
            "payload" => payload
          }
          result["source"] = source if source
          result
        end

        def to_meta
          {META_CREDENTIAL => to_dict}
        end

        def self.from_dict(data)
          new(
            challenge: MCPChallenge.from_dict(data["challenge"]),
            payload: data["payload"],
            source: data["source"]
          )
        end

        def self.from_meta(meta)
          return nil unless meta.key?(META_CREDENTIAL)

          from_dict(meta[META_CREDENTIAL])
        end

        def to_core
          request_json = Mpp::Json.compact_encode(challenge.request)
          request_b64 = Base64.urlsafe_encode64(request_json, padding: false)

          opaque_b64 = nil
          if challenge.opaque
            opaque_json = Mpp::Json.compact_encode(challenge.opaque)
            opaque_b64 = Base64.urlsafe_encode64(opaque_json, padding: false)
          end

          echo = Mpp::ChallengeEcho.new(
            id: challenge.id,
            realm: challenge.realm,
            method: challenge.method,
            intent: challenge.intent,
            request: request_b64,
            expires: challenge.expires,
            digest: challenge.digest,
            opaque: opaque_b64
          )
          Mpp::Credential.new(
            challenge: echo,
            payload: payload,
            source: source
          )
        end

        def self.from_core(credential, challenge)
          new(
            challenge: challenge,
            payload: credential.payload,
            source: credential.source
          )
        end
      end

      MCPReceipt = Data.define(:status, :challenge_id, :method, :timestamp,
        :reference, :settlement) do
        def initialize(status:, challenge_id:, method:, timestamp:,
          reference: nil, settlement: nil)
          super
        end

        def to_dict
          result = {
            "status" => status,
            "challengeId" => challenge_id,
            "method" => method,
            "timestamp" => timestamp
          }
          result["reference"] = reference if reference
          result["settlement"] = settlement if settlement
          result
        end

        def to_meta
          {META_RECEIPT => to_dict}
        end

        def self.from_dict(data)
          new(
            status: data["status"],
            challenge_id: data["challengeId"],
            method: data["method"],
            timestamp: data["timestamp"],
            reference: data["reference"],
            settlement: data["settlement"]
          )
        end

        def self.from_meta(meta)
          return nil unless meta.key?(META_RECEIPT)

          from_dict(meta[META_RECEIPT])
        end

        def to_core
          Mpp::Receipt.new(
            status: status,
            timestamp: Time.iso8601(timestamp.gsub("Z", "+00:00")),
            reference: reference || ""
          )
        end

        def self.from_core(receipt, challenge_id:, method:, settlement: nil)
          ts = receipt.timestamp.utc.iso8601
          ts = ts.sub(/\+00:00$/, "Z")

          new(
            status: receipt.status,
            challenge_id: challenge_id,
            method: method,
            timestamp: ts,
            reference: receipt.reference.empty? ? nil : receipt.reference,
            settlement: settlement
          )
        end
      end
    end
  end
end
