defmodule ServiceRadar.Repo.Migrations.CreateExposureCatalogViews do
  @moduledoc """
  Exposes flattened exposure dimensions without granting JDBC access to the
  assessment tables, fleet dictionary, agent inventory, or JSON documents.

  The chart's catalog-reader Job repeats the column grants when the reader
  role is created after this migration. Login remains CNPG-managed.
  """

  use Ecto.Migration

  @role "serviceradar_starrocks_reader"
  @grants [
    {"exposure_device_catalog",
     "device_ord, device_uid, hostname, device_type, vendor_name, partition, vlan_uid, owner_name, tag_site, is_available, agent_managed"},
    {"exposure_device_tags_catalog", "device_ord, tag_key, tag_value"}
  ]

  def up do
    execute("""
    CREATE VIEW platform.exposure_device_catalog AS
    SELECT o.ordinal AS device_ord, d.uid AS device_uid, d.hostname,
      d.type AS device_type, d.vendor_name, d.partition, d.vlan_uid,
      d.owner->>'name' AS owner_name, d.tags->>'site' AS tag_site,
      d.is_available,
      EXISTS (SELECT 1 FROM platform.ocsf_agents a WHERE a.device_uid = d.uid) AS agent_managed
    FROM platform.ocsf_devices d
    JOIN platform.device_fleet_ordinals o ON o.uid = d.uid
    WHERE d.deleted_at IS NULL AND NOT o.tombstoned
    """)

    execute("""
    CREATE VIEW platform.exposure_device_tags_catalog AS
    SELECT o.ordinal AS device_ord, tag.key AS tag_key, tag.value AS tag_value
    FROM platform.ocsf_devices d
    JOIN platform.device_fleet_ordinals o ON o.uid = d.uid
    CROSS JOIN LATERAL jsonb_each_text(d.tags) AS tag
    WHERE d.deleted_at IS NULL AND NOT o.tombstoned
    """)

    for {relation, columns} <- @grants do
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
          GRANT SELECT (#{columns}) ON platform.#{relation} TO #{@role};
        END IF;
      END $$;
      """)
    end
  end

  def down do
    execute("DROP VIEW IF EXISTS platform.exposure_device_tags_catalog")
    execute("DROP VIEW IF EXISTS platform.exposure_device_catalog")
  end
end
