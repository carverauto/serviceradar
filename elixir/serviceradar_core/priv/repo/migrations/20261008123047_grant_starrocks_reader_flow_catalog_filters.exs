defmodule ServiceRadar.Repo.Migrations.GrantStarrocksReaderFlowCatalogFilters do
  @moduledoc """
  Grants the catalog reader the current-state columns used by flow proximity
  and threat filters.

  These grants assumed a JDBC pass-through (`native_query`) that StarRocks 4.1
  does not have; it first ships in 4.2. The flow threat filters now read the
  scalar `ip_threat_intel_cache` columns (ip, matched, expires_at,
  max_severity) through the plain catalog. The `location`, `sources` and
  `indicator` grants are unused: the 4.1 JDBC catalog cannot read geography,
  `text[]` or `cidr` columns, so SRQL refuses the filters that need them.

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
