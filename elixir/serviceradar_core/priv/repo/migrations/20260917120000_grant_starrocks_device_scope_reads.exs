defmodule ServiceRadar.Repo.Migrations.GrantStarrocksDeviceScopeReads do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar_starrocks_reader') THEN
        GRANT SELECT (device_id, alias_type, state, alias_value)
          ON platform.device_alias_states TO serviceradar_starrocks_reader;
        GRANT SELECT (device_uid, sampler_address)
          ON platform.netflow_exporter_cache TO serviceradar_starrocks_reader;
      END IF;
    END$$
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar_starrocks_reader') THEN
        REVOKE SELECT (device_id, alias_type, state, alias_value)
          ON platform.device_alias_states FROM serviceradar_starrocks_reader;
        REVOKE SELECT (device_uid, sampler_address)
          ON platform.netflow_exporter_cache FROM serviceradar_starrocks_reader;
      END IF;
    END$$
    """)
  end
end
