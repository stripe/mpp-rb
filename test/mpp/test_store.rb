# frozen_string_literal: true

require "test_helper"

class TestStore < Minitest::Test
  def setup
    @store = Mpp::MemoryStore.new
  end

  def test_get_missing_key
    assert_nil @store.get("missing")
  end

  def test_put_and_get
    @store.put("key1", "value1")

    assert_equal "value1", @store.get("key1")
  end

  def test_delete
    @store.put("key1", "value1")
    @store.delete("key1")

    assert_nil @store.get("key1")
  end

  def test_delete_missing_key
    @store.delete("nonexistent")
  end

  def test_put_if_absent_new_key
    result = @store.put_if_absent("key1", "value1")

    assert result
    assert_equal "value1", @store.get("key1")
  end

  def test_put_if_absent_existing_key
    @store.put("key1", "value1")
    result = @store.put_if_absent("key1", "value2")

    refute result
    assert_equal "value1", @store.get("key1")
  end

  def test_overwrite_with_put
    @store.put("key1", "value1")
    @store.put("key1", "value2")

    assert_equal "value2", @store.get("key1")
  end
end
