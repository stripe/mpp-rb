# frozen_string_literal: true

require "test_helper"

class TestChallengeId < Minitest::Test
  # Cross-SDK conformance test vectors
  def test_basic_charge
    result = Mpp.generate_challenge_id(
      secret_key: "test-secret-key-12345",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {
        "amount" => "1000000",
        "currency" => "0x20c0000000000000000000000000000000000000",
        "recipient" => "0x1234567890abcdef1234567890abcdef12345678"
      }
    )

    assert_equal "XmJ98SdsAdzwP9Oa-8In322Uh6yweMO6rywdomWk_V4", result
  end

  def test_with_expires
    result = Mpp.generate_challenge_id(
      secret_key: "test-secret-key-12345",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {
        "amount" => "5000000",
        "currency" => "0x20c0000000000000000000000000000000000000",
        "recipient" => "0xabcdef1234567890abcdef1234567890abcdef12"
      },
      expires: "2026-01-29T12:00:00Z"
    )

    assert_equal "EvqUWMPJjqhoVJVG3mhTYVqCa3Mk7bUVd_OjeJGek1A", result
  end

  def test_with_digest
    result = Mpp.generate_challenge_id(
      secret_key: "my-server-secret",
      realm: "payments.example.org",
      method: "tempo",
      intent: "charge",
      request: {
        "amount" => "250000",
        "currency" => "USD",
        "recipient" => "0x9999999999999999999999999999999999999999"
      },
      digest: "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE="
    )

    assert_equal "qcJUPoapy4bFLznQjQUutwPLyXW7FvALrWA_sMENgAY", result
  end

  def test_full_challenge
    result = Mpp.generate_challenge_id(
      secret_key: "production-secret-abc123",
      realm: "api.tempo.xyz",
      method: "tempo",
      intent: "charge",
      request: {
        "amount" => "10000000",
        "currency" => "0x20c0000000000000000000000000000000000000",
        "recipient" => "0x742d35Cc6634C0532925a3b844Bc9e7595f1B0F2",
        "description" => "API access fee",
        "externalId" => "order-12345"
      },
      expires: "2026-02-01T00:00:00Z",
      digest: "sha-256=abc123def456"
    )

    assert_equal "J6w7zq6nHLnchss3AYbLxNirdpuaV8_Msn37DQSz6Bw", result
  end

  def test_different_secret_different_id
    result = Mpp.generate_challenge_id(
      secret_key: "different-secret-key",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {
        "amount" => "1000000",
        "currency" => "0x20c0000000000000000000000000000000000000",
        "recipient" => "0x1234567890abcdef1234567890abcdef12345678"
      }
    )

    assert_equal "_o55RP0duNvJYtw9PXnf44mGyY5ajV_wwGzoGdTFuNs", result
  end

  def test_empty_request
    result = Mpp.generate_challenge_id(
      secret_key: "test-key",
      realm: "test.example.com",
      method: "tempo",
      intent: "authorize",
      request: {}
    )

    assert_equal "MYEC2oq3_B3cHa_My1Lx3NQKn_iUiMfsns6361N0SX0", result
  end

  def test_unicode_in_description
    result = Mpp.generate_challenge_id(
      secret_key: "unicode-test-key",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {
        "amount" => "100",
        "currency" => "EUR",
        "recipient" => "0x1111111111111111111111111111111111111111",
        "description" => "Payment for café ☕"
      }
    )

    assert_equal "1_GKJqATKvVnIUY3f8MFq48bMs18JHz_3CBK8pu52yA", result
  end

  def test_nested_method_details
    result = Mpp.generate_challenge_id(
      secret_key: "nested-test-key",
      realm: "api.tempo.xyz",
      method: "tempo",
      intent: "charge",
      request: {
        "amount" => "5000000",
        "currency" => "0x20c0000000000000000000000000000000000000",
        "recipient" => "0x2222222222222222222222222222222222222222",
        "methodDetails" => {"chainId" => 42_431, "feePayer" => true}
      }
    )

    assert_equal "VkSq83C7vQFvdX3MqHM7s-N1QOo2nae4F1iHmbV5pgg", result
  end
end

class TestGoldenVectors < Minitest::Test
  SECRET = "test-vector-secret"

  def test_required_fields_only
    result = Mpp.generate_challenge_id(
      secret_key: SECRET, realm: "api.example.com", method: "tempo", intent: "charge",
      request: {"amount" => "1000000"}
    )

    assert_equal "X6v1eo7fJ76gAxqY0xN9Jd__4lUyDDYmriryOM-5FO4", result
  end

  def test_golden_with_expires
    result = Mpp.generate_challenge_id(
      secret_key: SECRET, realm: "api.example.com", method: "tempo", intent: "charge",
      request: {"amount" => "1000000"}, expires: "2025-01-06T12:00:00Z"
    )

    assert_equal "ChPX33RkKSZoSUyZcu8ai4hhkvjZJFkZVnvWs5s0iXI", result
  end

  def test_golden_with_digest
    result = Mpp.generate_challenge_id(
      secret_key: SECRET, realm: "api.example.com", method: "tempo", intent: "charge",
      request: {"amount" => "1000000"},
      digest: "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE"
    )

    assert_equal "JHB7EFsPVb-xsYCo8LHcOzeX1gfXWVoUSzQsZhKAfKM", result
  end

  def test_golden_with_expires_and_digest
    result = Mpp.generate_challenge_id(
      secret_key: SECRET, realm: "api.example.com", method: "tempo", intent: "charge",
      request: {"amount" => "1000000"},
      expires: "2025-01-06T12:00:00Z",
      digest: "sha-256=X48E9qOokqqrvdts8nOJRJN3OWDUoyWxBf7kbu9DBPE"
    )

    assert_equal "m39jbWWCIfmfJZSwCfvKFFtBl0Qwf9X4nOmDb21peLA", result
  end

  def test_multi_field_request
    result = Mpp.generate_challenge_id(
      secret_key: SECRET, realm: "api.example.com", method: "tempo", intent: "charge",
      request: {"amount" => "1000000", "currency" => "0x1234", "recipient" => "0xabcd"}
    )

    assert_equal "_H5TOnnlW0zduQ5OhQ3EyLVze_TqxLDPda2CGZPZxOc", result
  end

  def test_nested_method_details
    result = Mpp.generate_challenge_id(
      secret_key: SECRET, realm: "api.example.com", method: "tempo", intent: "charge",
      request: {"amount" => "1000000", "currency" => "0x1234", "methodDetails" => {"chainId" => 42_431}}
    )

    assert_equal "TqujwpuDDg_zsWGINAd5XObO2rRe6uYufpqvtDmr6N8", result
  end

  def test_empty_request
    result = Mpp.generate_challenge_id(
      secret_key: SECRET, realm: "api.example.com", method: "tempo", intent: "charge",
      request: {}
    )

    assert_equal "yLN7yChAejW9WNmb54HpJIWpdb1WWXeA3_aCx4dxmkU", result
  end

  def test_different_realm
    result = Mpp.generate_challenge_id(
      secret_key: SECRET, realm: "payments.other.com", method: "tempo", intent: "charge",
      request: {"amount" => "1000000"}
    )

    assert_equal "3F5bOo2a9RUihdwKk4hGRvBvzQmVPBMDvW0YM-8GD00", result
  end

  def test_different_method
    result = Mpp.generate_challenge_id(
      secret_key: SECRET, realm: "api.example.com", method: "stripe", intent: "charge",
      request: {"amount" => "1000000"}
    )

    assert_equal "o0ra2sd7HcB4Ph0Vns69gRDUhSj5WNOnUopcDqKPLz4", result
  end

  def test_different_intent
    result = Mpp.generate_challenge_id(
      secret_key: SECRET, realm: "api.example.com", method: "tempo", intent: "session",
      request: {"amount" => "1000000"}
    )

    assert_equal "aAY7_IEDzsznNYplhOSE8cERQxvjFcT4Lcn-7FHjLVE", result
  end
end

class TestChallengeCreate < Minitest::Test
  def test_creates_challenge_with_hmac_id
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret-key-12345",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {
        "amount" => "1000000",
        "currency" => "0x20c0000000000000000000000000000000000000",
        "recipient" => "0x1234567890abcdef1234567890abcdef12345678"
      }
    )

    assert_equal "XmJ98SdsAdzwP9Oa-8In322Uh6yweMO6rywdomWk_V4", challenge.id
    assert_equal "tempo", challenge.method
    assert_equal "charge", challenge.intent
  end

  def test_create_with_optional_fields
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret-key-12345",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {
        "amount" => "5000000",
        "currency" => "0x20c0000000000000000000000000000000000000",
        "recipient" => "0xabcdef1234567890abcdef1234567890abcdef12"
      },
      expires: "2026-01-29T12:00:00Z",
      description: "Test payment"
    )

    assert_equal "EvqUWMPJjqhoVJVG3mhTYVqCa3Mk7bUVd_OjeJGek1A", challenge.id
    assert_equal "2026-01-29T12:00:00Z", challenge.expires
    assert_equal "Test payment", challenge.description
  end
end

class TestChallengeVerify < Minitest::Test
  def test_verify_valid_challenge
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret-key-12345",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {
        "amount" => "1000000",
        "currency" => "0x20c0000000000000000000000000000000000000",
        "recipient" => "0x1234567890abcdef1234567890abcdef12345678"
      }
    )

    assert challenge.verify("test-secret-key-12345", "api.example.com")
  end

  def test_verify_invalid_secret
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret-key-12345",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"}
    )

    refute challenge.verify("wrong-secret", "api.example.com")
  end

  def test_verify_invalid_realm
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret-key-12345",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"}
    )

    refute challenge.verify("test-secret-key-12345", "wrong.realm.com")
  end

  def test_verify_tampered_challenge
    original = Mpp::Challenge.create(
      secret_key: "test-secret-key-12345",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"}
    )
    tampered = Mpp::Challenge.new(
      id: original.id,
      method: original.method,
      intent: original.intent,
      request: {"amount" => "9999999"}
    )

    refute tampered.verify("test-secret-key-12345", "api.example.com")
  end
end

class TestOpaque < Minitest::Test
  def test_meta_sets_opaque_on_challenge
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      meta: {"pi" => "pi_3abc123XYZ"}
    )

    assert_equal({"pi" => "pi_3abc123XYZ"}, challenge.opaque)
  end

  def test_opaque_is_nil_when_no_meta
    challenge = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"}
    )

    assert_nil challenge.opaque
  end

  def test_opaque_affects_challenge_id
    with_meta = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      meta: {"pi" => "pi_3abc123XYZ"}
    )
    without_meta = Mpp::Challenge.create(
      secret_key: "test-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"}
    )

    refute_equal with_meta.id, without_meta.id
  end

  def test_verify_succeeds_with_opaque
    challenge = Mpp::Challenge.create(
      secret_key: "my-secret",
      realm: "api.example.com",
      method: "tempo",
      intent: "charge",
      request: {"amount" => "1000000"},
      meta: {"pi" => "pi_3abc123XYZ"}
    )

    assert challenge.verify("my-secret", "api.example.com")
  end
end
