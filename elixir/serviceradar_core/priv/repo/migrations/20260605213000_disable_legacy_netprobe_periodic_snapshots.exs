defmodule ServiceRadar.Repo.Migrations.DisableLegacyNetprobePeriodicSnapshots do
  @moduledoc false
  use Ecto.Migration

  def up do
    # serviceradar:allow-startup-maintenance - bounded config normalization for
    # existing netprobe assignments; fresh installs have no rows to update.
    execute("""
    UPDATE platform.addon_assignments AS assignment
    SET params = jsonb_set(
          assignment.params,
          '{process_snapshot_interval_s}',
          '0'::jsonb,
          true
        ),
        updated_at = NOW()
    FROM platform.addon_packages AS package
    WHERE package.id = assignment.addon_package_id
      AND package.addon_id = 'netprobe'
      AND assignment.params ->> 'process_snapshot_interval_s' = '30'
    """)
  end

  def down do
    execute("""
    UPDATE platform.addon_assignments AS assignment
    SET params = jsonb_set(
          assignment.params,
          '{process_snapshot_interval_s}',
          '30'::jsonb,
          true
        ),
        updated_at = NOW()
    FROM platform.addon_packages AS package
    WHERE package.id = assignment.addon_package_id
      AND package.addon_id = 'netprobe'
      AND assignment.params ->> 'process_snapshot_interval_s' = '0'
    """)
  end
end
