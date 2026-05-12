defmodule ServiceRadar.Repo.Migrations.DisableManualPluginAssignmentsShadowedByPolicy do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    UPDATE platform.plugin_assignments AS manual
    SET enabled = false,
        updated_at = now()
    WHERE manual.source = 'manual'
      AND manual.enabled = true
      AND EXISTS (
        SELECT 1
        FROM platform.plugin_assignments AS policy
        WHERE policy.source = 'policy'
          AND policy.enabled = true
          AND policy.agent_uid = manual.agent_uid
          AND policy.plugin_package_id = manual.plugin_package_id
      )
    """)
  end

  def down do
    :ok
  end
end
