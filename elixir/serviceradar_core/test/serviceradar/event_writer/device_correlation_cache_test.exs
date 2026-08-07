defmodule ServiceRadar.EventWriter.DeviceCorrelationCacheTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.EventWriter.DeviceCorrelationCache

  @moduletag :requires_app

  setup do
    # Each test gets a freshly started cache so the named ETS table exists and
    # is empty. The cache fails open if the table is missing, so we assert on a
    # live table here.
    table = :"device_correlation_cache_test_#{System.unique_integer([:positive])}"
    name = :"device_correlation_cache_proc_#{System.unique_integer([:positive])}"

    pid = start_supervised!({DeviceCorrelationCache, name: name, table_name: table})

    on_exit(fn ->
      if Process.alive?(pid), do: :ok
    end)

    {:ok, pid: pid}
  end

  test "second resolve for the same candidate is served from cache without a DB hit" do
    parent = self()
    candidate = %{ip: "10.0.2.8", partition: "default"}

    resolver = fn ->
      send(parent, :resolver_called)
      "sr:device-cached"
    end

    # First call: cache miss -> resolver runs (one DB lookup).
    assert DeviceCorrelationCache.fetch(candidate, resolver) == "sr:device-cached"
    assert_received :resolver_called

    # Second call: cache hit -> resolver MUST NOT run (no DB lookup).
    boom = fn -> flunk("resolver should not run on a cache hit") end
    assert DeviceCorrelationCache.fetch(candidate, boom) == "sr:device-cached"

    # Equivalent candidate (same fields, different field order/whitespace) hits
    # the same entry.
    equivalent = %{partition: "default", ip: " 10.0.2.8 "}
    assert DeviceCorrelationCache.fetch(equivalent, boom) == "sr:device-cached"
  end

  test "negative results are cached so a confirmed miss does not re-hit the DB" do
    parent = self()
    candidate = %{hostname: "unknown-host"}

    resolver = fn ->
      send(parent, :resolver_called)
      nil
    end

    assert DeviceCorrelationCache.fetch(candidate, resolver) == nil
    assert_received :resolver_called

    boom = fn -> flunk("resolver should not run on a cached negative") end
    assert DeviceCorrelationCache.fetch(candidate, boom) == nil
  end

  test "distinct candidates do not collide" do
    a = %{ip: "10.0.0.1", partition: "default"}
    b = %{ip: "10.0.0.2", partition: "default"}

    assert DeviceCorrelationCache.fetch(a, fn -> "sr:a" end) == "sr:a"
    assert DeviceCorrelationCache.fetch(b, fn -> "sr:b" end) == "sr:b"

    assert DeviceCorrelationCache.fetch(a, fn -> flunk("a should be cached") end) == "sr:a"
    assert DeviceCorrelationCache.fetch(b, fn -> flunk("b should be cached") end) == "sr:b"
  end

  test "expired positive entries fall back to the resolver" do
    previous = Application.get_env(:serviceradar_core, :device_correlation_cache_ttl_ms)
    Application.put_env(:serviceradar_core, :device_correlation_cache_ttl_ms, 5)

    on_exit(fn ->
      restore_env(:device_correlation_cache_ttl_ms, previous)
    end)

    parent = self()
    candidate = %{agent_id: "agent-ttl"}

    resolver = fn ->
      send(parent, :resolver_called)
      "sr:ttl"
    end

    assert DeviceCorrelationCache.fetch(candidate, resolver) == "sr:ttl"
    assert_received :resolver_called

    # Let the entry expire.
    Process.sleep(20)

    assert DeviceCorrelationCache.fetch(candidate, resolver) == "sr:ttl"
    assert_received :resolver_called
  end

  test "cache_key is stable and order-independent for equivalent candidates" do
    a = DeviceCorrelationCache.cache_key(%{ip: "1.2.3.4", agent_id: "a", partition: "p"})
    b = DeviceCorrelationCache.cache_key(%{partition: "p", agent_id: "a", ip: "1.2.3.4"})
    assert a == b

    # Empty/whitespace-only values normalize to nil, so they don't change the key.
    c =
      DeviceCorrelationCache.cache_key(%{
        ip: "1.2.3.4",
        agent_id: "a",
        partition: "p",
        name: "  "
      })

    assert a == c

    different = DeviceCorrelationCache.cache_key(%{ip: "1.2.3.5", agent_id: "a", partition: "p"})
    refute a == different
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
