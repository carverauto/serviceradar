defmodule ServiceRadar.Repo.Migrations.AddAgentIdsToSnmpProfiles do
  @moduledoc """
  Adds agent_ids column to snmp_profiles for first-class per-agent targeting.

  This mirrors how sweep_groups pin to an agent (sweep_groups.agent_id), but as
  a multi-agent array so an operator can say "only agents X and Y run this SNMP
  profile".

  Backward-compatible: the column defaults to an empty array. An empty agent_ids
  preserves today's behavior (target_query + is_default fallback decide which
  agents/devices poll). A non-empty agent_ids restricts the profile to exactly
  those agent UIDs.
  """

  use Ecto.Migration

  def up do
    alter table(:snmp_profiles, prefix: "platform") do
      add :agent_ids, {:array, :string}, null: false, default: []
    end

    create index(:snmp_profiles, [:agent_ids],
             using: "gin",
             prefix: "platform",
             name: "snmp_profiles_agent_ids_idx"
           )
  end

  def down do
    drop index(:snmp_profiles, [:agent_ids],
           prefix: "platform",
           name: "snmp_profiles_agent_ids_idx"
         )

    alter table(:snmp_profiles, prefix: "platform") do
      remove :agent_ids
    end
  end
end
