# frozen_string_literal: true

require "test_helper"
require "webmock/minitest"

class TestClientPreferences < Minitest::Test
  class Method
    attr_reader :name, :intents, :signed

    def initialize(name: "tempo", intents: ["charge"])
      @name = name
      @intents = intents.to_h { |intent| [intent, Object.new] }
      @signed = []
    end

    def create_credential(challenge)
      @signed << challenge
      Mpp::Credential.new(challenge: challenge.to_echo, payload: {})
    end
  end

  URL = "https://api.example.com/preferences"

  def test_advertises_supported_intents_on_initial_request_and_retry
    method = Method.new(intents: ["charge", "custom"])
    challenge = offer
    stub_offers([challenge])
    headers = {"X-Request" => "original"}

    response = Mpp::Client::Transport.new(methods: [method]).get(URL, headers: headers)

    assert_equal "200", response.code
    assert_equal({"X-Request" => "original"}, headers)
    assert_requested(:get, URL, headers: {"Accept-Payment" => "tempo/charge, tempo/custom"}, times: 2)
  end

  def test_preference_ranking
    cases = [
      ["tempo/charge;q=0.2, other/charge;q=0.9", "other"],
      ["tempo/charge;q=0, */*;q=1", "other"],
      ["*/charge", "tempo"],
      ["other/charge;q=0.5, tempo/charge;q=0.5", "tempo"],
      ["other/*", "other"],
      ["tempo/charge;q=0, other/charge;q=0", nil]
    ]
    cases.each do |header, expected|
      WebMock.reset!
      methods = [Method.new, Method.new(name: "other")]
      stub_offers([offer, offer(method: "other")])
      transport = Mpp::Client::Transport.new(methods: methods)

      response = transport.get(URL, headers: {"accept-payment" => header})

      signed = methods.flat_map(&:signed)
      assert_equal expected ? "200" : "402", response.code, header
      assert_equal expected ? [expected] : [], signed.map(&:method), header
      assert_requested(:get, URL, headers: {"Accept-Payment" => header}, times: expected ? 2 : 1)
    end
  end

  def test_skips_unsupported_intents_even_with_wildcard_preferences
    method = Method.new
    stub_offers([offer(intent: "custom"), offer])

    response = Mpp::Client::Transport.new(methods: [method]).get(URL, headers: {"Accept-Payment" => "*/*"})

    assert_equal "200", response.code
    assert_equal ["charge"], method.signed.map(&:intent)
  end

  def test_preserves_handlers_with_the_same_name_and_different_intents
    charge = Method.new
    custom = Method.new(intents: ["custom"])
    stub_offers([offer])

    response = Mpp::Client::Transport.new(methods: [charge, custom]).get(URL)

    assert_equal "200", response.code
    assert_equal 1, charge.signed.length
    assert_empty custom.signed
  end

  def test_reads_preferences_across_multiple_header_values
    tempo = Method.new
    other = Method.new(name: "other")
    stub_offers([offer, offer(method: "other")], merged: false)

    response = Mpp::Client::Transport.new(methods: [tempo, other]).get(URL,
      headers: {"Accept-Payment" => "other/charge;q=1, tempo/charge;q=0"})

    assert_equal "200", response.code
    assert_empty tempo.signed
    assert_equal 1, other.signed.length
  end

  def test_rejects_malformed_explicit_preferences_before_network_io
    ["", "tempo/charge;q=2", "tempo/charge;q=nope"].each do |header|
      transport = Mpp::Client::Transport.new(methods: [Method.new])
      assert_raises(ArgumentError) { transport.get(URL, headers: {"Accept-Payment" => header}) }
    end
    assert_not_requested(:get, URL)
  end

  private

  def offer(method: "tempo", intent: "charge")
    Mpp::Challenge.create(secret_key: "test-secret", realm: "api.example.com",
      method: method, intent: intent, request: {"amount" => "1"}, expires: Mpp::Expires.minutes(5))
  end

  def stub_offers(challenges, merged: true)
    headers = challenges.map { |challenge| challenge.to_www_authenticate("api.example.com") }
    stub_request(:get, URL)
      .to_return(status: 402, headers: {"WWW-Authenticate" => merged ? headers.join(", ") : headers})
      .then.to_return(status: 200)
  end
end
