defmodule ServiceRadar.Repo.Migrations.PruneInvalidAgentDeviceIdentifiers do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM platform.device_identifiers di
    WHERE di.identifier_type = 'agent_id'
      AND NOT EXISTS (
        SELECT 1
        FROM platform.ocsf_agents a
        WHERE a.uid = di.identifier_value
          AND a.device_uid = di.device_id
      );
    """)
  end

  def down do
    :ok
  end
end
