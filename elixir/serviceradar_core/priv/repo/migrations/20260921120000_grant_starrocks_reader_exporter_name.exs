defmodule ServiceRadar.Repo.Migrations.GrantStarrocksReaderExporterName do
  @moduledoc """
  Lets the StarRocks JDBC catalog reader resolve a flow's exporter name.

  The warehouse row carries only `sampler_address`; the name lives in
  `netflow_exporter_cache`, which CNPG reads with a subquery and the warehouse
  dialect joins through the catalog. The reader already held
  `device_uid, sampler_address` on this table for device scoping
  (`20260918120000_create_starrocks_catalog_reader_role`), and a column-scoped
  grant does not extend itself: without `exporter_name` the join fails on the
  Frontend with "permission denied for table netflow_exporter_cache".

  Guarded on the role existing, for the reason that migration sets out: on a
  default CNPG cluster the migration user cannot create the role, so it may
  legitimately be absent, and granting to a missing role is an error that would
  abort every migration after this one. Where CNPG creates the role later, the
  chart's catalog-reader Job applies the same grant.
  """

  use Ecto.Migration

  @role "serviceradar_starrocks_reader"
  @relation "netflow_exporter_cache"
  @columns "exporter_name"

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
