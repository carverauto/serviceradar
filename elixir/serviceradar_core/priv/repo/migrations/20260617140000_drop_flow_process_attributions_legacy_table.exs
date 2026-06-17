defmodule ServiceRadar.Repo.Migrations.DropFlowProcessAttributionsLegacyTable do
  @moduledoc """
  Drops the legacy append-only `flow_process_attributions` table.

  This table was superseded by `flow_process_attribution_current` (an UPSERT
  keyed on `(partition, attribution_key)`) introduced in
  20260606160000_create_flow_process_attribution_current.exs. The flow
  attribution pipeline dual-wrote both tables and correlation `UNION ALL`ed
  them, but `_current` retention (>= 60 min) already exceeds the correlation
  window (~30 min), so the legacy arm was fully redundant.

  The legacy INSERT ran a `NOT EXISTS` self-anti-join against this
  churn-bloated table and was the single biggest demo-DB CPU hot path
  (~29% of total exec time, mean ~3.3s/call, ~1.8GB for ~12 min of data).
  Dropping it also drops its indexes and reclaims the bloat.

  The up migration drops the table (idempotent). The down migration recreates
  the empty table shell and its indexes, mirroring
  20260602120000_create_flow_process_attributions.exs and the follow-on index
  migrations; it does not repopulate data (the data lived only in `_current`).
  """
  use Ecto.Migration

  @table "flow_process_attributions"

  def up do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      observed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
      partition         TEXT        NOT NULL DEFAULT 'default',
      agent_id          TEXT,
      proto             INTEGER     NOT NULL,
      local_ip          TEXT        NOT NULL,
      local_port        INTEGER     NOT NULL DEFAULT 0,
      remote_ip         TEXT        NOT NULL,
      remote_port       INTEGER     NOT NULL DEFAULT 0,
      pid               INTEGER,
      comm              TEXT,
      cmdline           TEXT,
      uid               INTEGER,
      container_id      TEXT,
      workload_identity JSONB
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attributions_match
      ON #{schema}.#{@table} (partition, proto, observed_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attributions_endpoints
      ON #{schema}.#{@table} (local_ip, remote_ip)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_flow_process_attributions_observed_at
      ON #{schema}.#{@table} (observed_at)
    """)
  end
end
