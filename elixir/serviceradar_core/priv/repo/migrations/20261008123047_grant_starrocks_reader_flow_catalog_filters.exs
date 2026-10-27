defmodule ServiceRadar.Repo.Migrations.GrantStarrocksReaderFlowCatalogFilters do
  @moduledoc """
  Grants the catalog reader the current-state columns used by flow proximity
  and threat filters.

  These grants assumed a JDBC pass-through (`native_query`) that StarRocks 4.1
  does not have; it first ships in 4.2. The 4.1 JDBC catalog cannot read the
  `location` geography, the `sources` `text[]` or the `indicator` `cidr`, so
  those grants are unused. The flow filters read the scalar cache columns
  directly, and migration 20261026190000 adds the `_catalog` views and the
  `latitude`/`longitude` grant that `threat_source`, `threat_indicator` and
  `near` read instead.

  Role creation remains CNPG-managed. The chart's catalog-reader Job converges
  the same grants when the catalog is enabled after this migration has run.
  """

  use Ecto.Migration

  @role "serviceradar_starrocks_reader"
  @grants [
    {"ip_geo_enrichment_cache", "location"},
    {"ip_threat_intel_cache", "ip, matched, expires_at, sources, max_severity"},
    {"threat_intel_indicators", "indicator, expires_at"}
  ]

  def up do
    for {relation, columns} <- @grants do
      execute(guarded("GRANT", relation, columns, "TO"))
    end
  end

  def down do
    for {relation, columns} <- Enum.reverse(@grants) do
      execute(guarded("REVOKE", relation, columns, "FROM"))
    end
  end

  defp guarded(verb, relation, columns, preposition) do
    """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}')
         AND EXISTS (
           SELECT 1 FROM information_schema.tables
           WHERE table_schema = 'platform' AND table_name = '#{relation}'
         ) THEN
        EXECUTE '#{verb} SELECT (#{columns}) ON platform.#{relation} #{preposition} #{@role}';
      END IF;
    END $$;
    """
  end
end
