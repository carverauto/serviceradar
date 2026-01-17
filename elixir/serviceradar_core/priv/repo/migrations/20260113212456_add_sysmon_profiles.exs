defmodule ServiceRadar.Repo.Migrations.AddSysmonProfiles do
  @moduledoc """
  Creates sysmon_profiles and sysmon_profile_assignments tables for system monitoring configuration.

  These tables are instance-scoped.
  """

  use Ecto.Migration

  def up do
    # sysmon_profiles table
    create table(:sysmon_profiles, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :sample_interval, :text, null: false, default: "10s"
      add :collect_cpu, :boolean, null: false, default: true
      add :collect_memory, :boolean, null: false, default: true
      add :collect_disk, :boolean, null: false, default: true
      add :collect_network, :boolean, null: false, default: false
      add :collect_processes, :boolean, null: false, default: false
      add :disk_paths, {:array, :text}, null: false, default: fragment("ARRAY['/']::text[]")
      add :thresholds, :map, null: false, default: %{}
      add :is_default, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:sysmon_profiles, [:name], name: "sysmon_profiles_unique_name_index")

    # sysmon_profile_assignments table
    create table(:sysmon_profile_assignments, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true

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

    # Unique index for device assignments
    create unique_index(:sysmon_profile_assignments, [:profile_id, :device_uid],
             name: "sysmon_profile_assignments_unique_device_index",
             where: "assignment_type = 'device' AND device_uid IS NOT NULL"
           )

    # Unique index for tag assignments
    create unique_index(:sysmon_profile_assignments, [:profile_id, :tag_key, :tag_value],
             name: "sysmon_profile_assignments_unique_tag_index",
             where: "assignment_type = 'tag' AND tag_key IS NOT NULL"
           )

    # Index for looking up assignments by device
    create index(:sysmon_profile_assignments, [:device_uid],
             name: "sysmon_profile_assignments_device_uid_index",
             where: "assignment_type = 'device'"
           )

    # Index for looking up assignments by tag
    create index(:sysmon_profile_assignments, [:tag_key, :tag_value],
             name: "sysmon_profile_assignments_tag_index",
             where: "assignment_type = 'tag'"
           )
  end

  def down do
    drop table(:sysmon_profile_assignments)
    drop table(:sysmon_profiles)
  end
end
