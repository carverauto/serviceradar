defmodule ServiceRadar.Repo.Migrations.CreateDuskProfiles do
  @moduledoc """
  Creates the dusk_profiles table for Dusk blockchain node monitoring configuration.

  DuskProfiles define how agents monitor Dusk blockchain nodes:
  - WebSocket address for monitoring
  - Connection timeout settings
  - SRQL target_query for device targeting
  - Priority for resolution order
  """

  use Ecto.Migration

  def up do
    create table(:dusk_profiles, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :name, :text, null: false
      add :description, :text
      add :node_address, :text, null: false
      add :timeout, :text, null: false, default: "5m"
      add :is_default, :boolean, null: false, default: false
      add :enabled, :boolean, null: false, default: true
      add :target_query, :text
      add :priority, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
      add :updated_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create unique_index(:dusk_profiles, [:name])
    create index(:dusk_profiles, [:is_default])
    create index(:dusk_profiles, [:enabled])
    create index(:dusk_profiles, [:priority])
  end

  def down do
    drop table(:dusk_profiles)
  end
end
