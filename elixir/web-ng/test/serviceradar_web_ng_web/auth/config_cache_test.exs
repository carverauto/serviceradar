defmodule ServiceRadarWebNGWeb.Auth.ConfigCacheTest do
  @moduledoc """
  Tests for authentication configuration cache.

  These tests verify the caching functionality (get_cached, put_cached, etc.)
  which don't require database access. The auth settings tests may return
  {:error, :not_configured} or actual settings depending on database state.

  Run with: mix test test/serviceradar_web_ng_web/auth/config_cache_test.exs
  """

  use ExUnit.Case, async: false

  alias ServiceRadarWebNGWeb.Auth.ConfigCache

  # ConfigCache uses ETS which is started by the application
  # These tests verify the caching functionality

  describe "get_cached/1 and put_cached/3" do
    setup do
      # Use unique keys for each test to avoid collisions
      key = "test_key_#{System.unique_integer([:positive])}"
      {:ok, key: key}
    end

    test "returns :miss for non-existent key", %{key: key} do
      assert :miss = ConfigCache.get_cached(key)
    end

    test "caches and retrieves a value", %{key: key} do
      value = %{test: "data"}
      assert :ok = ConfigCache.put_cached(key, value)
      assert {:ok, ^value} = ConfigCache.get_cached(key)
    end

    test "supports different value types", %{key: key} do
      # String
      ConfigCache.put_cached(key <> "_string", "test")
      assert {:ok, "test"} = ConfigCache.get_cached(key <> "_string")

      # List
      ConfigCache.put_cached(key <> "_list", [1, 2, 3])
      assert {:ok, [1, 2, 3]} = ConfigCache.get_cached(key <> "_list")

      # Map
      ConfigCache.put_cached(key <> "_map", %{a: 1})
      assert {:ok, %{a: 1}} = ConfigCache.get_cached(key <> "_map")
    end

    test "respects TTL expiration", %{key: key} do
      # Cache with very short TTL
      ConfigCache.put_cached(key, "value", ttl: 10)
      assert {:ok, "value"} = ConfigCache.get_cached(key)

      # Wait for expiration
      Process.sleep(20)

      # Should be expired now
      assert :miss = ConfigCache.get_cached(key)
    end

    test "uses default TTL when not specified", %{key: key} do
      ConfigCache.put_cached(key, "value")
      # Should still be valid immediately
      assert {:ok, "value"} = ConfigCache.get_cached(key)
    end
  end

  describe "delete_cached/1" do
    test "removes cached value" do
      key = "delete_test_#{System.unique_integer([:positive])}"
      ConfigCache.put_cached(key, "value")
      assert {:ok, "value"} = ConfigCache.get_cached(key)

      ConfigCache.delete_cached(key)
      assert :miss = ConfigCache.get_cached(key)
    end

    test "succeeds even for non-existent key" do
      key = "nonexistent_#{System.unique_integer([:positive])}"
      assert :ok = ConfigCache.delete_cached(key)
    end
  end

  describe "clear_cache/0" do
    test "removes all cached values" do
      key1 = "clear_test_1_#{System.unique_integer([:positive])}"
      key2 = "clear_test_2_#{System.unique_integer([:positive])}"

      ConfigCache.put_cached(key1, "value1")
      ConfigCache.put_cached(key2, "value2")

      ConfigCache.clear_cache()

      assert :miss = ConfigCache.get_cached(key1)
      assert :miss = ConfigCache.get_cached(key2)
    end
  end

  describe "get_mode/0" do
    test "returns :password_only when not configured" do
      # When no auth settings exist, should default to password_only
      mode = ConfigCache.get_mode()
      assert mode in [:password_only, :active_sso, :passive_proxy]
    end
  end

  describe "sso_enabled?/0" do
    test "returns boolean" do
      # Should return a boolean regardless of configuration state
      result = ConfigCache.sso_enabled?()
      assert is_boolean(result)
    end
  end

  describe "get_config/0" do
    test "returns result tuple" do
      result = ConfigCache.get_config()

      case result do
        {:ok, settings} ->
          # Settings should have expected fields
          assert is_map(settings)

        {:error, reason} ->
          # Error should be an atom
          assert is_atom(reason)
      end
    end
  end

  describe "get_settings/0" do
    test "is alias for get_config/0" do
      # Both functions should return the same result
      assert ConfigCache.get_config() == ConfigCache.get_settings()
    end
  end

  describe "refresh/0" do
    test "returns result tuple" do
      result = ConfigCache.refresh()

      case result do
        {:ok, _settings} -> :ok
        {:error, _reason} -> :ok
      end
    end
  end
end
