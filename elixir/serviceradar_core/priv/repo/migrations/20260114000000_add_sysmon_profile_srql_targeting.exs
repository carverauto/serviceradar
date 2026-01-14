defmodule ServiceRadar.Repo.Migrations.AddSysmonProfileSrqlTargeting do
  @moduledoc """
  Adds target_query and priority columns to sysmon_profiles for SRQL-based device targeting.

  This enables profiles to define which devices they apply to using SRQL queries
  like "in:devices tags.role:database" or "in:devices hostname:prod-*".

  The priority column determines evaluation order when resolving which profile
  applies to a device (higher priority = evaluated first).
  """

  use Ecto.Migration

  def up do
    alter table(:sysmon_profiles) do
      add :target_query, :text, null: true
      add :priority, :integer, null: false, default: 0
    end

    # Index for efficient lookup of targeting profiles
    create index(:sysmon_profiles, [:enabled, :is_default, :priority],
             name: "sysmon_profiles_targeting_index",
             where: "enabled = true AND is_default = false AND target_query IS NOT NULL"
           )
  end

  def down do
    drop index(:sysmon_profiles, name: "sysmon_profiles_targeting_index")

    alter table(:sysmon_profiles) do
      remove :target_query
      remove :priority
    end
  end
end
