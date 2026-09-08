defmodule ServiceRadar.Repo.Migrations.EnforceEndpointInventoryCanonicalDeviceUids do
  @moduledoc false
  use Ecto.Migration

  @tables [
    "endpoint_inventory_scans",
    "endpoint_inventory_artifacts",
    "endpoint_inventory_packages",
    "endpoint_inventory_scan_history",
    "endpoint_inventory_package_events",
    "endpoint_inventory_package_count_history",
    "endpoint_inventory_cpe_count_history"
  ]

  def up do
    # serviceradar:allow-startup-maintenance - schema-critical bounded cleanup
    # before adding sr: device_uid constraints across endpoint inventory tables.
    Enum.each(@tables, fn table ->
      execute("""
      UPDATE platform.#{table}
      SET device_uid = NULL
      WHERE device_uid IS NOT NULL
        AND device_uid NOT LIKE 'sr:%'
      """)

      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1
          FROM pg_constraint c
          JOIN pg_class r ON r.oid = c.conrelid
          JOIN pg_namespace n ON n.oid = r.relnamespace
          WHERE n.nspname = 'platform'
            AND r.relname = '#{table}'
            AND c.conname = '#{constraint_name(table)}'
        ) THEN
          ALTER TABLE platform.#{table}
          ADD CONSTRAINT #{constraint_name(table)}
          CHECK (device_uid IS NULL OR device_uid LIKE 'sr:%');
        END IF;
      END $$;
      """)
    end)
  end

  def down do
    Enum.each(@tables, fn table ->
      execute("""
      ALTER TABLE platform.#{table}
      DROP CONSTRAINT IF EXISTS #{constraint_name(table)}
      """)
    end)
  end

  defp constraint_name(table), do: "#{table}_device_uid_sr_check"
end
