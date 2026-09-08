defmodule ServiceRadar.Repo.Migrations.EnforceSingleEnabledPluginAssignment do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:plugin_assignments, prefix: "platform") do
      add_if_not_exists :plugin_id, :text
    end

    # serviceradar:allow-startup-maintenance - schema-critical bounded normalization before
    # plugin_id becomes required and the enabled-assignment uniqueness index is created.
    execute("""
    UPDATE platform.plugin_assignments AS assignment
    SET plugin_id = package.plugin_id,
        updated_at = now()
    FROM platform.plugin_packages AS package
    WHERE assignment.plugin_package_id = package.id
      AND assignment.plugin_id IS NULL
    """)

    execute("""
    WITH ranked AS (
      SELECT
        assignment.id,
        row_number() OVER (
          PARTITION BY assignment.agent_uid, assignment.plugin_id
          ORDER BY
            CASE WHEN assignment.source = 'policy' THEN 0 ELSE 1 END,
            assignment.updated_at DESC,
            assignment.inserted_at DESC,
            assignment.id
        ) AS rank
      FROM platform.plugin_assignments AS assignment
      WHERE assignment.enabled = true
        AND assignment.plugin_id IS NOT NULL
    )
    UPDATE platform.plugin_assignments AS assignment
    SET enabled = false,
        updated_at = now()
    FROM ranked
    WHERE assignment.id = ranked.id
      AND ranked.rank > 1
    """)

    execute("""
    ALTER TABLE platform.plugin_assignments
    ALTER COLUMN plugin_id SET NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS plugin_assignments_plugin_id_index
    ON platform.plugin_assignments (plugin_id)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS plugin_assignments_one_enabled_per_agent_plugin_index
    ON platform.plugin_assignments (agent_uid, plugin_id)
    WHERE enabled = true
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.plugin_assignments_one_enabled_per_agent_plugin_index")
    execute("DROP INDEX IF EXISTS platform.plugin_assignments_plugin_id_index")

    alter table(:plugin_assignments, prefix: "platform") do
      remove_if_exists :plugin_id
    end
  end
end
