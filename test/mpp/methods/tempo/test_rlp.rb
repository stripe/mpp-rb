# frozen_string_literal: true

require "test_helper"

class TestTempoRlp < Minitest::Test
  def test_default_codec_matches_standard_vectors
    require "rlp"
    codec = Mpp::Methods::Tempo::Rlp.resolve

    assert_equal "80", codec.encode("".b).unpack1("H*")
    assert_equal "83646f67", codec.encode("dog".b).unpack1("H*")
    assert_equal "c88363617483646f67", codec.encode(["cat".b, "dog".b]).unpack1("H*")
    assert_equal ["cat", "dog"], codec.decode(["c88363617483646f67"].pack("H*"))
  end

  def test_resolve_accepts_codec_contract
    codec = Struct.new(:encoded) do
      def encode(value) = self.encoded = value
      def decode(value) = value
    end.new

    assert_same codec, Mpp::Methods::Tempo::Rlp.resolve(codec)
    assert_equal [:nested, [1, 2]], codec.encode([:nested, [1, 2]])
  end

  def test_resolve_rejects_incomplete_codec
    error = assert_raises(ArgumentError) do
      Mpp::Methods::Tempo::Rlp.resolve(Object.new)
    end

    assert_includes error.message, "encode and decode"
  end
end
