defmodule ServiceRadar.Repo.Migrations.AddFlowAttributionPartialWorkloadBackfillIndex do
  @moduledoc """
  Extends workload-identity backfill indexing to partial workload JSON.

  Flow attribution rows may already have pod/container metadata from netprobe but
  still miss the authoritative workload context supplied by the standalone
  workload-identity stream.
  """
  use Ecto.Migration

  @schema "platform"
  @table "flow_process_attribution_current"

  def up do
    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attr_current_partial_workload_backfill
      ON #{@schema}.#{@table} (partition, agent_id, container_id, observed_at DESC)
      WHERE container_id IS NOT NULL
        AND (workload_identity IS NULL OR NOT (workload_identity ? 'context_name'))
    """)
  end

  def down do
    execute("""
    DROP INDEX IF EXISTS #{@schema}.idx_flow_process_attr_current_partial_workload_backfill
    """)
  end
end
