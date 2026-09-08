defmodule ServiceRadar.Repo.Migrations.CreateRuntimeTopologyLinks do
  @moduledoc false
  use Ecto.Migration

  def change do
    create table(:runtime_topology_links, primary_key: false, prefix: "platform") do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :topology_plane, :text, null: false
      add :local_device_id, :text, null: false
      add :neighbor_device_id, :text, null: false
      add :relation_type, :text
      add :evidence_class, :text
      add :observed_at, :utc_datetime_usec
      add :row, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:runtime_topology_links, [:topology_plane, :observed_at],
             prefix: "platform",
             name: "runtime_topology_links_plane_observed_idx"
           )

    create index(:runtime_topology_links, [:local_device_id],
             prefix: "platform",
             name: "runtime_topology_links_local_device_idx"
           )

    create index(:runtime_topology_links, [:neighbor_device_id],
             prefix: "platform",
             name: "runtime_topology_links_neighbor_device_idx"
           )

    create table(:runtime_topology_projection_meta, primary_key: false, prefix: "platform") do
      add :projection_name, :text, null: false, primary_key: true
      add :refreshed_at, :utc_datetime_usec, null: false
      add :row_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end
  end
end
