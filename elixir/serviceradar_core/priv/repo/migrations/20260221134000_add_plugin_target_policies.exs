defmodule ServiceRadar.Repo.Migrations.AddPluginTargetPolicies do
  use Ecto.Migration

  def up do
    create_if_not_exists table(:plugin_target_policies, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text

      add :plugin_package_id,
          references(:plugin_packages,
            column: :id,
            name: "plugin_target_policies_plugin_package_id_fkey",
            type: :uuid,
            prefix: "platform",
            on_delete: :delete_all
          ),
          null: false

      add :input_definitions, {:array, :map}, null: false, default: []
      add :params_template, :map, null: false, default: %{}
      add :interval_seconds, :bigint, null: false, default: 60
      add :timeout_seconds, :bigint, null: false, default: 10
      add :chunk_size, :bigint, null: false, default: 100
      add :max_targets, :bigint, null: false, default: 10_000
      add :enabled, :boolean, null: false, default: true
      add :last_reconciled_at, :utc_datetime_usec
      add :last_reconcile_summary, :map, null: false, default: %{}

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create_if_not_exists index(:plugin_target_policies, [:enabled],
                           name: "plugin_target_policies_enabled_index",
                           prefix: "platform"
                         )

    create_if_not_exists index(:plugin_target_policies, [:plugin_package_id],
                           name: "plugin_target_policies_package_index",
                           prefix: "platform"
                         )
  end

  def down do
    drop_if_exists index(:plugin_target_policies, [:plugin_package_id],
                     name: "plugin_target_policies_package_index",
                     prefix: "platform"
                   )

    drop_if_exists index(:plugin_target_policies, [:enabled],
                     name: "plugin_target_policies_enabled_index",
                     prefix: "platform"
                   )

    drop constraint(:plugin_target_policies, "plugin_target_policies_plugin_package_id_fkey",
           prefix: "platform"
         )

    drop table(:plugin_target_policies, prefix: "platform")
  end
end
