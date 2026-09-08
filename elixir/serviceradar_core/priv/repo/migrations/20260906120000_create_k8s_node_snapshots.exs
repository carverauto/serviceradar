defmodule ServiceRadar.Repo.Migrations.CreateK8sNodeSnapshots do
  @moduledoc false
  use Ecto.Migration

  def up do
    schema = prefix() || "platform"

    create table(:k8s_node_snapshots, primary_key: false, prefix: schema) do
      add :cluster_id, :text, primary_key: true, null: false
      add :snapshot_at, :timestamptz, null: false
    end

    execute("""
    INSERT INTO #{schema}.k8s_node_snapshots (cluster_id, snapshot_at)
    SELECT cluster_id, MAX(GREATEST(snapshot_at, deleted_at))
    FROM #{schema}.k8s_nodes_current
    GROUP BY cluster_id
    """)
  end

  def down do
    drop table(:k8s_node_snapshots, prefix: prefix() || "platform")
  end
end
