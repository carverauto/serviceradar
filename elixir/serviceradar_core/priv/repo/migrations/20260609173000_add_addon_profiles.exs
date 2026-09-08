defmodule ServiceRadar.Repo.Migrations.AddAddonProfiles do
  use Ecto.Migration

  def up do
    create_if_not_exists table(:addon_profiles, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :addon_id, :text, null: false

      add :addon_package_id,
          references(:addon_packages,
            column: :id,
            name: "addon_profiles_addon_package_id_fkey",
            type: :uuid,
            prefix: "platform",
            on_delete: :delete_all
          ),
          null: false

      add :target_query, :text, null: false
      add :params, :map, null: false, default: %{}
      add :args, {:array, :text}, null: false, default: []
      add :priority, :bigint, null: false, default: 100
      add :max_targets, :bigint, null: false, default: 10_000
      add :metadata, :map, null: false, default: %{}
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

    create_if_not_exists index(:addon_profiles, [:enabled],
                           name: "addon_profiles_enabled_index",
                           prefix: "platform"
                         )

    create_if_not_exists index(:addon_profiles, [:addon_package_id],
                           name: "addon_profiles_package_index",
                           prefix: "platform"
                         )

    alter table(:addon_assignments, prefix: "platform") do
      add_if_not_exists :addon_profile_id, :uuid
      add_if_not_exists :profile_reconcile_status, :text
      add_if_not_exists :profile_reconcile_error, :text
      add_if_not_exists :profile_last_reconciled_at, :utc_datetime_usec
      add_if_not_exists :profile_metadata, :map, null: false, default: %{}
    end

    execute("""
    ALTER TABLE platform.addon_assignments
    DROP CONSTRAINT IF EXISTS addon_assignments_addon_profile_id_fkey
    """)

    execute("""
    ALTER TABLE platform.addon_assignments
    ADD CONSTRAINT addon_assignments_addon_profile_id_fkey
    FOREIGN KEY (addon_profile_id)
    REFERENCES platform.addon_profiles(id)
    ON DELETE SET NULL
    """)

    create_if_not_exists index(:addon_assignments, [:source, :addon_profile_id],
                           name: "addon_assignments_source_profile_index",
                           prefix: "platform"
                         )
  end

  def down do
    drop_if_exists index(:addon_assignments, [:source, :addon_profile_id],
                     name: "addon_assignments_source_profile_index",
                     prefix: "platform"
                   )

    execute("""
    ALTER TABLE platform.addon_assignments
    DROP CONSTRAINT IF EXISTS addon_assignments_addon_profile_id_fkey
    """)

    alter table(:addon_assignments, prefix: "platform") do
      remove_if_exists :profile_metadata
      remove_if_exists :profile_last_reconciled_at
      remove_if_exists :profile_reconcile_error
      remove_if_exists :profile_reconcile_status
      remove_if_exists :addon_profile_id
    end

    drop_if_exists index(:addon_profiles, [:addon_package_id],
                     name: "addon_profiles_package_index",
                     prefix: "platform"
                   )

    drop_if_exists index(:addon_profiles, [:enabled],
                     name: "addon_profiles_enabled_index",
                     prefix: "platform"
                   )

    drop constraint(:addon_profiles, "addon_profiles_addon_package_id_fkey",
           prefix: "platform"
         )

    drop table(:addon_profiles, prefix: "platform")
  end
end
