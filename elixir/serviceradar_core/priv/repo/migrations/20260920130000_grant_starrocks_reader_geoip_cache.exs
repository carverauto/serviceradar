defmodule ServiceRadar.Repo.Migrations.GrantStarrocksReaderGeoipCache do
  @moduledoc """
  Lets the StarRocks JDBC catalog reader resolve a flow endpoint's country.

  Neither backend stores a country on the flow row: GeoIP answers change and
  expire, so CNPG joins `ip_geo_enrichment_cache` at query time and the
  warehouse dialect does the same through the catalog. Column-scoped to exactly
  what that join reads, like every other grant this role holds
  (`20260918120000_create_starrocks_catalog_reader_role`).

  Guarded on the role existing, for the reason that migration sets out: on a
  default CNPG cluster the migration user cannot create the role, so it may
  legitimately be absent, and granting to a missing role is an error that would
  abort every migration after this one. Where CNPG creates the role later, the
  chart's catalog-reader Job applies the same grant.
  """

  use Ecto.Migration

  @role "serviceradar_starrocks_reader"
  @relation "ip_geo_enrichment_cache"
  @columns "ip, country_iso2, expires_at"

  def up, do: execute(guarded("GRANT", "TO"))

  def down, do: execute(guarded("REVOKE", "FROM"))

  defp guarded(verb, preposition) do
    """
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}')
         AND EXISTS (
           SELECT 1 FROM information_schema.tables
           WHERE table_schema = 'platform' AND table_name = '#{@relation}'
         ) THEN
        EXECUTE '#{verb} SELECT (#{@columns}) ON platform.#{@relation} #{preposition} #{@role}';
      END IF;
    END $$;
    """
  end
end
