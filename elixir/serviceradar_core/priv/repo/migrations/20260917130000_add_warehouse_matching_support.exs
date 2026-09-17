defmodule ServiceRadar.Repo.Migrations.AddWarehouseMatchingSupport do
  use Ecto.Migration

  def up do
    execute("CREATE SEQUENCE IF NOT EXISTS platform.flow_attribution_update_version AS bigint")

    execute("""
    CREATE OR REPLACE VIEW platform.netflow_local_cidrs_catalog AS
    SELECT partition, enabled,
           substring(encode(inet_send(network(cidr)::inet), 'hex') from 9) AS first_ip_hex,
           substring(encode(inet_send(broadcast(cidr)), 'hex') from 9) AS last_ip_hex
    FROM platform.netflow_local_cidrs
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar_starrocks_reader') THEN
        GRANT SELECT ON platform.netflow_local_cidrs_catalog TO serviceradar_starrocks_reader;
      END IF;
    END$$
    """)
  end

  def down do
    execute("DROP VIEW IF EXISTS platform.netflow_local_cidrs_catalog")
    execute("DROP SEQUENCE IF EXISTS platform.flow_attribution_update_version")
  end
end
