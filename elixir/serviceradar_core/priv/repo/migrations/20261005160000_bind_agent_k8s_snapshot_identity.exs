defmodule ServiceRadar.Repo.Migrations.BindAgentK8sSnapshotIdentity do
  @moduledoc false
  use Ecto.Migration

  def change do
    schema = prefix() || "platform"

    create table(:k8s_inventory_cluster_bindings, primary_key: false, prefix: schema) do
      add :cluster_id, :text, primary_key: true, null: false

      add :agent_id,
          references(:ocsf_agents,
            column: :uid,
            type: :text,
            prefix: schema,
            on_delete: :restrict
          ),
          null: false

      add :partition_id, :text, null: false
      add :changed_by, :text, null: false, default: "system"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:k8s_inventory_cluster_bindings, [:agent_id], prefix: schema)

    create table(:k8s_public_endpoint_snapshots, primary_key: false, prefix: schema) do
      add :cluster_id, :text, primary_key: true, null: false
      add :snapshot_at, :utc_datetime_usec, null: false
      add :source_mode, :text, null: false
      add :agent_id, :text
      add :partition_id, :text
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
