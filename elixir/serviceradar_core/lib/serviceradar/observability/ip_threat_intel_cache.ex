defmodule ServiceRadar.Observability.IpThreatIntelCache do
  @moduledoc """
  Cache for per-IP threat intel matches.

  This keeps UI lookups cheap without re-evaluating indicator membership constantly.
  """

  use ServiceRadar.Observability.IpLookupCacheResource,
    table: "ip_threat_intel_cache",
    read_policy: :public,
    upsert_roles: [:system],
    fields: [
      {:matched, :boolean, [allow_nil?: false, default: false]},
      {:match_count, :integer, [allow_nil?: false, default: 0]},
      {:max_severity, :integer, []},
      {:sources, {:array, :string}, [allow_nil?: false, default: []]}
    ]
end
