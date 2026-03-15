defmodule ServiceRadar.Observability.IpRdnsCache do
  @moduledoc """
  Cache for reverse DNS lookups.

  This is a bounded cache keyed by IP:
  - one row per IP
  - `expires_at` controls TTL
  - background jobs refresh and prune expired rows
  """

  use ServiceRadar.Observability.IpLookupCacheResource,
    table: "ip_rdns_cache",
    fields: [
      {:hostname, :string, []},
      {:status, :string, []}
    ]
end
