defmodule ServiceRadar.Repo.Migrations.CreateStarrocksCatalogReaderRole do
  @moduledoc """
  Owns the `serviceradar_starrocks_reader` role and its complete grant set.

  The earlier grant migrations are each wrapped in an `IF EXISTS (... pg_roles
  ...)` guard, so on a deployment where core migrates before an operator creates
  the role by hand they all no-op silently and every cut-over flows query that
  mentions `direction` or `device_id` then fails with permission denied. Create
  the role here instead, so the grants can never be skipped.

  The role is created without a password: `LOGIN` with a NULL password cannot
  authenticate under scram-sha-256 or md5, so the StarRocks FE still needs an
  operator to run `ALTER ROLE serviceradar_starrocks_reader PASSWORD '...'` and
  put that password in the catalog secret. Grants stay column-scoped to exactly
  what the compiled catalog subqueries read.
  """

  use Ecto.Migration

  @grants [
    "GRANT USAGE ON SCHEMA platform TO serviceradar_starrocks_reader",
    "GRANT SELECT ON platform.prefix_tags_catalog TO serviceradar_starrocks_reader",
    "GRANT SELECT ON platform.netflow_local_cidrs_catalog TO serviceradar_starrocks_reader",
    "GRANT SELECT (uid, hostname, ip) ON platform.ocsf_devices TO serviceradar_starrocks_reader",
    "GRANT SELECT (device_id, alias_type, state, alias_value) ON platform.device_alias_states TO serviceradar_starrocks_reader",
    "GRANT SELECT (device_uid, sampler_address) ON platform.netflow_exporter_cache TO serviceradar_starrocks_reader"
  ]

  @revokes [
    "REVOKE SELECT (device_uid, sampler_address) ON platform.netflow_exporter_cache FROM serviceradar_starrocks_reader",
    "REVOKE SELECT (device_id, alias_type, state, alias_value) ON platform.device_alias_states FROM serviceradar_starrocks_reader",
    "REVOKE SELECT (uid, hostname, ip) ON platform.ocsf_devices FROM serviceradar_starrocks_reader",
    "REVOKE SELECT ON platform.netflow_local_cidrs_catalog FROM serviceradar_starrocks_reader",
    "REVOKE SELECT ON platform.prefix_tags_catalog FROM serviceradar_starrocks_reader",
    "REVOKE USAGE ON SCHEMA platform FROM serviceradar_starrocks_reader"
  ]

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar_starrocks_reader') THEN
        CREATE ROLE serviceradar_starrocks_reader LOGIN;
      END IF;

      EXECUTE format(
        'GRANT CONNECT ON DATABASE %I TO serviceradar_starrocks_reader',
        current_database()
      );
    END$$
    """)

    Enum.each(@grants, &execute/1)
  end

  def down do
    Enum.each(@revokes, &execute/1)

    execute("""
    DO $$
    BEGIN
      EXECUTE format(
        'REVOKE CONNECT ON DATABASE %I FROM serviceradar_starrocks_reader',
        current_database()
      );
    END$$
    """)

    execute("DROP ROLE IF EXISTS serviceradar_starrocks_reader")
  end
end
