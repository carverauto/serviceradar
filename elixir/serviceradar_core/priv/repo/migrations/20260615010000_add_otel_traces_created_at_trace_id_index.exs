defmodule ServiceRadar.Repo.Migrations.AddOtelTracesCreatedAtTraceIdIndex do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_otel_traces_created_at_trace_id
    ON platform.otel_traces (created_at DESC, trace_id)
    """)
  end

  def down do
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS platform.idx_otel_traces_created_at_trace_id
    """)
  end
end
