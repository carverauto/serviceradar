defmodule ServiceRadar.Repo.Migrations.CreateFlowProcessAttributions do
  @moduledoc """
  Stores netprobe process attributions (5-tuple -> process) pushed by agents over
  the agent-gateway pipeline. NetFlow/sFlow remains the authoritative flow source
  (ocsf_network_activity); these rows only supply the WHO. A correlation worker
  (ServiceRadar.FlowAttribution.Correlator) joins them against recent NetFlow and
  marks matching flows event_type=attributed_flow.

  Idempotent and safe to re-run.
  """
  use Ecto.Migration

  @table "flow_process_attributions"

  def up do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      observed_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
      partition     TEXT        NOT NULL DEFAULT 'default',
      agent_id      TEXT,
      proto         INTEGER     NOT NULL,
      local_ip      TEXT        NOT NULL,
      local_port    INTEGER     NOT NULL DEFAULT 0,
      remote_ip     TEXT        NOT NULL,
      remote_port   INTEGER     NOT NULL DEFAULT 0,
      pid           INTEGER,
      comm          TEXT,
      cmdline       TEXT,
      uid           INTEGER,
      container_id  TEXT
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

  def down do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end
end
