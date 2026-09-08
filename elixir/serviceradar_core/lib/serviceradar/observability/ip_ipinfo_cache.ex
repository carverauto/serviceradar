defmodule ServiceRadar.Observability.IpIpinfoCache do
  @moduledoc """
  Cache for ipinfo.io/lite enrichment.

  Bounded by IP with TTL (`expires_at`).
  """

  use ServiceRadar.Observability.IpLookupCacheResource,
    table: "ip_ipinfo_cache",
    read_policy: :public,
    fields: [
      {:country_code, :string, []},
      {:country_name, :string, []},
      {:region, :string, []},
      {:city, :string, []},
      {:timezone, :string, []},
      {:as_number, :integer, []},
      {:as_name, :string, []},
      {:as_domain, :string, []}
    ]
end
