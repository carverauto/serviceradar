defmodule ServiceRadar.Repo.Migrations.SetAgentDevicesManagedTrusted do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE #{prefix() || "platform"}.ocsf_devices
    SET is_managed = true,
        is_trusted = true
    WHERE agent_id IS NOT NULL
      AND agent_id <> ''
    """)
  end

  def down do
    :ok
  end
end
