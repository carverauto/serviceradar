defmodule ServiceRadar.Repo.Migrations.AddDeviceActiveLifecycle do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE platform.ocsf_devices
    ADD COLUMN IF NOT EXISTS is_active boolean NOT NULL DEFAULT true
    """)

    create_if_not_exists index(:ocsf_devices, [:is_active],
                           prefix: "platform",
                           name: "ocsf_devices_is_active_idx"
                         )
  end

  def down do
    drop_if_exists index(:ocsf_devices, [:is_active],
                     prefix: "platform",
                     name: "ocsf_devices_is_active_idx"
                   )

    execute("ALTER TABLE platform.ocsf_devices DROP COLUMN IF EXISTS is_active")
  end
end
