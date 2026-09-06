defmodule ServiceRadar.Repo.Migrations.CreateK8sNodesCurrent do
  @moduledoc """
  Current-state inventory of Kubernetes Nodes (Ready condition, role)
  produced by serviceradar-k8s-inventory on inventory.k8s.nodes.
  """
  use Ecto.Migration

  @table "k8s_nodes_current"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      node_key         TEXT        NOT NULL,
      cluster_id       TEXT        NOT NULL,
      name             TEXT        NOT NULL,
      uid              TEXT,
      role             TEXT        NOT NULL,
      ready            BOOLEAN     NOT NULL,
      ready_reason     TEXT,
      ready_message    TEXT,
      unschedulable    BOOLEAN     NOT NULL DEFAULT false,
      internal_ip      TEXT,
      external_ip      TEXT,
      kubelet_version  TEXT,
      os_image         TEXT,
      observed_at      TIMESTAMPTZ NOT NULL,
      snapshot_at      TIMESTAMPTZ NOT NULL,
      deleted_at       TIMESTAMPTZ,
      inserted_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
      CONSTRAINT k8s_nodes_current_pkey PRIMARY KEY (node_key)
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_k8s_nodes_current_cluster_name
      ON #{schema}.#{@table} (cluster_id, name)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_k8s_nodes_current_cluster_ready
      ON #{schema}.#{@table} (cluster_id, ready)
      WHERE deleted_at IS NULL
    """)
  end

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
