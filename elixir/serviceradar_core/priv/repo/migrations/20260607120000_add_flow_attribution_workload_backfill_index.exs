defmodule ServiceRadar.Repo.Migrations.AddFlowAttributionWorkloadBackfillIndex do
  @moduledoc """
  Adds a targeted lookup index for late workload-identity backfills.

  Workload Identity snapshots can arrive after netprobe process attribution rows.
  Backfills join recent attribution rows by partition, agent, and container ID, so
  this index keeps the join bounded as current-state attribution cardinality grows.
  """
  use Ecto.Migration

  @schema "platform"
  @table "flow_process_attribution_current"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attr_current_workload_backfill
      ON #{@schema}.#{@table} (partition, agent_id, container_id, observed_at DESC)
      WHERE container_id IS NOT NULL AND workload_identity IS NULL
    """)
  end

  def down do
    execute("""
    DROP INDEX IF EXISTS #{@schema}.idx_flow_process_attr_current_workload_backfill
    """)
  end
end
