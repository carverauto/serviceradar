defmodule ServiceRadar.Repo.Migrations.AddAvailabilitySourceProfiles do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:availability_source_profiles, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :srql_query, :text, null: false
      add :agent_id, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :priority, :integer, null: false, default: 100
      add :match_count, :integer, null: false, default: 0
      add :applied_count, :integer, null: false, default: 0
      add :last_evaluated_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:availability_source_profiles, ["lower(name)"],
             prefix: "platform",
             name: "availability_source_profiles_name_uidx"
           )

    create index(:availability_source_profiles, [:enabled, :priority],
             prefix: "platform",
             name: "availability_source_profiles_enabled_priority_idx"
           )

    create index(:availability_source_profiles, [:agent_id],
             prefix: "platform",
             name: "availability_source_profiles_agent_id_idx"
           )

    alter table(:ocsf_devices, prefix: "platform") do
      add :availability_source_profile_id,
          references(:availability_source_profiles,
            type: :uuid,
            prefix: "platform",
            on_delete: :nilify_all
          )
    end

    create index(:ocsf_devices, [:availability_source_profile_id],
             prefix: "platform",
             name: "ocsf_devices_availability_source_profile_id_idx"
           )
  end
end
