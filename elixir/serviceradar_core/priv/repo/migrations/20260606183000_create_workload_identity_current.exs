defmodule ServiceRadar.Repo.Migrations.CreateWorkloadIdentityCurrent do
  @moduledoc """
  Creates current-state storage for standalone workload identity observations.

  This table stores coalesced container/pod identity by agent and container ID.
  Raw retention and cold-storage export are separate follow-up tasks.
  """
  use Ecto.Migration

  @schema "platform"
  @table "workload_identity_current"

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{@schema}.#{@table} (
      observed_at        TIMESTAMPTZ NOT NULL,
      inserted_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
      partition          TEXT        NOT NULL DEFAULT 'default',
      agent_id           TEXT        NOT NULL,
      gateway_id         TEXT,
      container_id       TEXT        NOT NULL,
      pod_uid            TEXT,
      pod_namespace      TEXT,
      pod_name           TEXT,
      container_name     TEXT,
      image              TEXT,
      runtime_source     TEXT,
      confidence         TEXT,
      degradation_reason TEXT,
      identity           JSONB       NOT NULL DEFAULT '{}'::jsonb,
      CONSTRAINT workload_identity_current_unique
        UNIQUE (partition, agent_id, container_id)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_workload_identity_current_observed_at
      ON #{@schema}.#{@table} (observed_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_workload_identity_current_pod
      ON #{@schema}.#{@table} (partition, pod_namespace, pod_name)
      WHERE pod_namespace IS NOT NULL AND pod_name IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_workload_identity_current_pod_uid
      ON #{@schema}.#{@table} (partition, pod_uid)
      WHERE pod_uid IS NOT NULL
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS #{@schema}.#{@table}")
  end
end
