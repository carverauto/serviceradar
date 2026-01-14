defmodule ServiceRadar.Repo.Migrations.DropSysmonProfileAssignments do
  @moduledoc """
  Drops the sysmon_profile_assignments table.

  Profile targeting is now handled via SRQL queries stored in the
  `target_query` column of `sysmon_profiles`. The separate assignments
  table is no longer needed.
  """

  use Ecto.Migration

  def up do
    drop_if_exists table(:sysmon_profile_assignments)
  end

  def down do
    # Recreate the assignments table if rolling back
    create table(:sysmon_profile_assignments, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :tenant_id, :uuid, null: false

      add :profile_id,
          references(:sysmon_profiles,
            column: :id,
            name: "sysmon_profile_assignments_profile_id_fkey",
            type: :uuid,
            on_delete: :delete_all
          ),
          null: false

      add :assignment_type, :text, null: false
      add :device_uid, :text
      add :tag_key, :text
      add :tag_value, :text
      add :priority, :integer, null: false, default: 0

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:sysmon_profile_assignments, [:tenant_id, :profile_id, :device_uid],
             name: "sysmon_profile_assignments_unique_device_index",
             where: "assignment_type = 'device' AND device_uid IS NOT NULL"
           )

    create unique_index(:sysmon_profile_assignments, [:tenant_id, :profile_id, :tag_key, :tag_value],
             name: "sysmon_profile_assignments_unique_tag_index",
             where: "assignment_type = 'tag' AND tag_key IS NOT NULL"
           )

    create index(:sysmon_profile_assignments, [:device_uid],
             name: "sysmon_profile_assignments_device_uid_index",
             where: "assignment_type = 'device'"
           )

    create index(:sysmon_profile_assignments, [:tag_key, :tag_value],
             name: "sysmon_profile_assignments_tag_index",
             where: "assignment_type = 'tag'"
           )
  end
end
