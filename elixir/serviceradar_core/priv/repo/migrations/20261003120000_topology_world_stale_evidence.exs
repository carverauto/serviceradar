defmodule ServiceRadar.Repo.Migrations.TopologyWorldStaleEvidence do
  @moduledoc false
  use Ecto.Migration

  def up do
    alter table(:topology_world_relations, prefix: "platform") do
      add(:stale, :boolean, null: false, default: false)
      add(:last_seen, :text, null: true)
    end

    alter table(:topology_world_layouts, prefix: "platform") do
      add(:pipeline_stats, :map, null: false, default: %{})
    end
  end

  def down do
    alter table(:topology_world_layouts, prefix: "platform") do
      remove(:pipeline_stats)
    end

    alter table(:topology_world_relations, prefix: "platform") do
      remove(:last_seen)
      remove(:stale)
    end
  end
end
