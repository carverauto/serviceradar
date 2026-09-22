defmodule ServiceRadar.Repo.Migrations.GrantStarrocksReaderDeviceIdentity do
  @moduledoc """
  Lets the StarRocks JDBC catalog reader resolve a device the way CNPG does.

  A log row carries no device uid and an event may be keyed under a hostname or
  an address, so `device_id:` on either dataset resolves the uid through the
  inventory. CNPG reads `ocsf_devices`, `device_identifiers` and
  `discovered_interfaces` for that (`rust/srql/src/query/logs/metadata.rs`,
  `rust/srql/src/query/events/filters.rs`), and the warehouse dialect runs the
  same lookups through the catalog.

  Two of the columns CNPG reads cannot cross the catalog: measured on StarRocks
  3.5.21, a PostgreSQL `text[]` (`discovered_interfaces.ip_addresses`) and a
  `jsonb` (`ocsf_devices.metadata`) both arrive as `UNKNOWN_TYPE`, and any
  query naming them is refused at analysis. They are reshaped on this side
  instead, as `netflow_local_cidrs_catalog` already does for `cidr`:

    * `device_interface_addresses_catalog` is one row per interface address.
    * `device_inventory_aliases_catalog` is one row per name the inventory
      knows a device by -- the alias list in `query/events/filters.rs`. It
      exposes the five metadata keys that list names, not the document.

  Grants are column-scoped to exactly what the compiled subqueries read, like
  every other grant this role holds
  (`20260918120000_create_starrocks_catalog_reader_role`), and guarded on the
  role and the relation existing for the reason that migration sets out: on a
  default CNPG cluster the migration user cannot create the role, so it may
  legitimately be absent, and granting to a missing role is an error that would
  abort every migration after this one. Where CNPG creates the role later, the
  chart's catalog-reader Job applies the same grants.
  """

  use Ecto.Migration

  @role "serviceradar_starrocks_reader"

  @grants [
    {"ocsf_devices", "uid_alt, name"},
    {"device_identifiers", "device_id, identifier_type, identifier_value"},
    {"discovered_interfaces", "device_id, device_ip"},
    {"device_interface_addresses_catalog", "device_id, ip"},
    {"device_inventory_aliases_catalog", "uid, uid_alt, alias"}
  ]

  def up do
    execute("""
    CREATE OR REPLACE VIEW platform.device_interface_addresses_catalog AS
    SELECT device_id, unnest(ip_addresses) AS ip
    FROM platform.discovered_interfaces
    """)

    execute("""
    CREATE OR REPLACE VIEW platform.device_inventory_aliases_catalog AS
    SELECT DISTINCT d.uid, d.uid_alt, NULLIF(BTRIM(aliases.alias), '') AS alias
    FROM platform.ocsf_devices AS d
    CROSS JOIN LATERAL (
      VALUES
        (d.uid),
        (d.uid_alt),
        (d.hostname),
        (d.name),
        (d.ip),
        (d.agent_id),
        (d.metadata->>'sys_name'),
        (d.metadata->>'snmp_name'),
        (d.metadata->>'controller_name'),
        (d.metadata->>'unifi_device_id'),
        (d.metadata->>'device_id')
    ) AS aliases(alias)
    WHERE NULLIF(BTRIM(aliases.alias), '') IS NOT NULL
    """)

    for {relation, columns} <- @grants do
      execute(guarded("GRANT", relation, columns, "TO"))
    end
  end

  def down do
    for {relation, columns} <- Enum.reverse(@grants) do
      execute(guarded("REVOKE", relation, columns, "FROM"))
    end

    execute("DROP VIEW IF EXISTS platform.device_inventory_aliases_catalog")
    execute("DROP VIEW IF EXISTS platform.device_interface_addresses_catalog")
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
