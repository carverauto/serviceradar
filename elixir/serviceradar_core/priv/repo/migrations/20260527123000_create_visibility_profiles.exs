defmodule ServiceRadar.Repo.Migrations.CreateVisibilityProfiles do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:visibility_profiles, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :enabled, :boolean, null: false, default: true
      add :target_query, :text
      add :priority, :integer, null: false, default: 0
      add :capture_interfaces, {:array, :text}, null: false, default: []

      add :fingerprint, :map,
        null: false,
        default: %{"tcp" => true, "tls" => true, "http" => true}

      add :dpi, :map
      add :flow_attribution, :map
      add :process_snapshot_interval_s, :integer
      add :sample_interval_ms, :integer, null: false, default: 60_000
      add :retention_days, :integer, null: false, default: 30
      add :partition_id, :text, null: false, default: "default"

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:visibility_profiles, [:partition_id, :name],
             name: "visibility_profiles_unique_partition_name_index",
             prefix: "platform"
           )

    create index(:visibility_profiles, [:enabled, :priority],
             name: "visibility_profiles_enabled_priority_index",
             prefix: "platform"
           )

    execute("""
    ALTER TABLE platform.visibility_profiles
    ADD CONSTRAINT visibility_profiles_sample_interval_ms_check
    CHECK (sample_interval_ms >= 0)
    """)

    execute("""
    ALTER TABLE platform.visibility_profiles
    ADD CONSTRAINT visibility_profiles_retention_days_check
    CHECK (retention_days >= 1)
    """)

    execute("""
    ALTER TABLE platform.visibility_profiles
    ADD CONSTRAINT visibility_profiles_process_snapshot_interval_s_check
    CHECK (process_snapshot_interval_s IS NULL OR process_snapshot_interval_s >= 0)
    """)

    create table(:visibility_profile_versions, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :version_action_type, :text, null: false
      add :version_action_name, :text, null: false
      add :version_action_inputs, :map, null: false, default: %{}
      add :partition_id, :text, null: false
      add :version_source_id, :uuid, null: false
      add :changes, :map
      add :actor, :map
      add :actor_id, :text
      add :request_id, :text

      add :version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:visibility_profile_versions, [:version_source_id],
             name: :visibility_profile_versions_source_idx,
             prefix: "platform"
           )

    create index(:visibility_profile_versions, [:partition_id, :version_inserted_at],
             name: :visibility_profile_versions_partition_inserted_idx,
             prefix: "platform"
           )
  end

  def down do
    drop_if_exists index(:visibility_profile_versions, [:partition_id, :version_inserted_at],
                     name: :visibility_profile_versions_partition_inserted_idx,
                     prefix: "platform"
                   )

    drop_if_exists index(:visibility_profile_versions, [:version_source_id],
                     name: :visibility_profile_versions_source_idx,
                     prefix: "platform"
                   )

    drop_if_exists table(:visibility_profile_versions, prefix: "platform")

    drop_if_exists index(:visibility_profiles, [:enabled, :priority],
                     name: "visibility_profiles_enabled_priority_index",
                     prefix: "platform"
                   )

    drop_if_exists unique_index(:visibility_profiles, [:partition_id, :name],
                     name: "visibility_profiles_unique_partition_name_index",
                     prefix: "platform"
                   )

    drop table(:visibility_profiles, prefix: "platform")
  end
end
