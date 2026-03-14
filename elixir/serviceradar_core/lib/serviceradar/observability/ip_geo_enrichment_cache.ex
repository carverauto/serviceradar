defmodule ServiceRadar.Observability.IpGeoEnrichmentCache do
  @moduledoc """
  Cache for IP GeoIP/ASN enrichment.

  This is a bounded cache keyed by IP:
  - one row per IP
  - `expires_at` controls TTL
  - background jobs refresh and prune expired rows
  """

  use ServiceRadar.Observability.IpLookupCacheResource,
    table: "ip_geo_enrichment_cache",
    fields: [
      {:asn, :integer, []},
      {:as_org, :string, []},
      {:country_iso2, :string, []},
      {:country_name, :string, []},
      {:region, :string, []},
      {:city, :string, []},
      {:latitude, :float, []},
      {:longitude, :float, []},
      {:timezone, :string, []},
      {:is_private, :boolean, [allow_nil?: false, default: false]}
    ]
end
