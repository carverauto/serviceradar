defmodule ServiceRadar.Repo.Migrations.TopologyWorldRelationEligibility do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:topology_world_relations, prefix: "platform") do
      add(:telemetry_eligible, :boolean, null: false, default: false)
      add(:kind, :text, null: false, default: fragment("'CANONICAL_TOPOLOGY'"))
    end
  end

  def down do
    alter table(:topology_world_relations, prefix: "platform") do
      remove(:kind)
      remove(:telemetry_eligible)
    end
  end
end
