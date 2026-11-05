defmodule ServiceRadar.Repo.Migrations.AddAvailabilityLastResolvedAtToDevices do
  use Ecto.Migration

  def up do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.ocsf_devices
      ADD COLUMN IF NOT EXISTS availability_last_resolved_at TIMESTAMP
    """)
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    ALTER TABLE #{schema}.ocsf_devices
      DROP COLUMN IF EXISTS availability_last_resolved_at
    """)
  end
end
