defmodule ServiceRadar.Repo.Migrations.AddPolicyFieldsToPluginAssignments do
  use Ecto.Migration

  def up do
    alter table(:plugin_assignments, prefix: "platform") do
      add_if_not_exists :source, :text, null: false, default: "manual"
      add_if_not_exists :source_key, :text
      add_if_not_exists :policy_id, :text
    end

    execute("""
    UPDATE platform.plugin_assignments
    SET source = 'manual'
    WHERE source IS NULL
    """)

    drop_if_exists unique_index(:plugin_assignments, [:agent_uid, :plugin_package_id],
                     name: "plugin_assignments_unique_agent_package_index",
                     prefix: "platform"
                   )

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS plugin_assignments_unique_manual_agent_package_index
    ON platform.plugin_assignments (agent_uid, plugin_package_id)
    WHERE source = 'manual'
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS plugin_assignments_unique_source_key_index
    ON platform.plugin_assignments (source, source_key)
    WHERE source_key IS NOT NULL
    """)

    create_if_not_exists index(:plugin_assignments, [:source, :policy_id],
                           name: "plugin_assignments_source_policy_index",
                           prefix: "platform"
                         )
  end

  def down do
    drop_if_exists index(:plugin_assignments, [:source, :policy_id],
                     name: "plugin_assignments_source_policy_index",
                     prefix: "platform"
                   )

    execute("DROP INDEX IF EXISTS platform.plugin_assignments_unique_source_key_index")
    execute("DROP INDEX IF EXISTS platform.plugin_assignments_unique_manual_agent_package_index")

    create_if_not_exists unique_index(:plugin_assignments, [:agent_uid, :plugin_package_id],
                           name: "plugin_assignments_unique_agent_package_index",
                           prefix: "platform"
                         )

    alter table(:plugin_assignments, prefix: "platform") do
      remove_if_exists :policy_id
      remove_if_exists :source_key
      remove_if_exists :source
    end
  end
end
