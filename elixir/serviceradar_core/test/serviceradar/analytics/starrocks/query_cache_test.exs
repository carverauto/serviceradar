defmodule ServiceRadar.Analytics.StarRocks.QueryCacheTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.QueryCache

  @moduletag :db_free

  @query "in:flows time:last_1h stats:\"sum(bytes_in) as bytes_in\" limit:10"
  @bounds %{start: ~U[2026-01-15 09:00:00Z], end: ~U[2026-01-15 10:00:00Z]}

  test "tenant and actor isolation produce distinct keys for the same query" do
    alpha =
      QueryCache.key(%{
        tenant_id: "tenant-alpha",
        actor_id: "actor-alpha",
        authorization_scope: "devices:read",
        authorization_version: 1,
        backend_generation: "starrocks-flows-1",
        query: @query,
        bounds: @bounds,
        timezone: "Etc/UTC"
      })

    bravo =
      QueryCache.key(%{
        tenant_id: "tenant-bravo",
        actor_id: "actor-alpha",
        authorization_scope: "devices:read",
        authorization_version: 1,
        backend_generation: "starrocks-flows-1",
        query: @query,
        bounds: @bounds,
        timezone: "Etc/UTC"
      })

    refute alpha == bravo
  end

  test "revoked access cannot reuse a prior cache entry" do
    live =
      QueryCache.key(%{
        tenant_id: "tenant-alpha",
        actor_id: "actor-alpha",
        authorization_scope: "devices:read",
        authorization_version: 4,
        backend_generation: "starrocks-flows-1",
        query: @query,
        bounds: @bounds,
        timezone: "Etc/UTC"
      })

    revoked =
      QueryCache.key(%{
        tenant_id: "tenant-alpha",
        actor_id: "actor-alpha",
        authorization_scope: "devices:read",
        authorization_version: 5,
        backend_generation: "starrocks-flows-1",
        query: @query,
        bounds: @bounds,
        timezone: "Etc/UTC"
      })

    refute live == revoked
  end

  test "backend generation, bounds and timezone are part of the key" do
    base = %{
      tenant_id: "tenant-alpha",
      actor_id: "actor-alpha",
      authorization_scope: "devices:read",
      authorization_version: 1,
      backend_generation: "starrocks-flows-1",
      query: @query,
      bounds: @bounds,
      timezone: "Etc/UTC"
    }

    refute QueryCache.key(base) ==
             QueryCache.key(Map.put(base, :backend_generation, "starrocks-flows-2"))

    refute QueryCache.key(base) ==
             QueryCache.key(Map.put(base, :timezone, "America/Chicago"))

    refute QueryCache.key(base) ==
             QueryCache.key(
               Map.put(base, :bounds, %{start: @bounds.start, end: ~U[2026-01-15 11:00:00Z]})
             )
  end
end
