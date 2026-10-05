defmodule ServiceRadar.Repo.Migrations.DropFlowProcessAttributionCurrent do
  @moduledoc """
  Drops `flow_process_attribution_current` and, with it, its indexes.

  Netprobe attribution observations now travel on JetStream
  (`flows.attribution.observations`) into the append-only StarRocks table
  `flow_process_attribution_observations`, and correlation runs in the
  warehouse (openspec change move-flow-attribution-to-starrocks). Nothing
  writes or reads this table any more. Its rows were observations that stop
  mattering after the 30-minute correlation window, so nothing is migrated.

  The down migration recreates the empty table shell with its unique key; it
  does not restore data.
  """
  use Ecto.Migration

  @table "flow_process_attribution_current"

  def up do
    schema = prefix() || "platform"
    execute("DROP TABLE IF EXISTS #{schema}.#{@table}")
  end

  def down do
    schema = prefix() || "platform"

    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.#{@table} (
      observed_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
      inserted_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
      partition         TEXT        NOT NULL DEFAULT 'default',
      attribution_key   TEXT        NOT NULL,
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
      workload_identity JSONB,
      CONSTRAINT flow_process_attribution_current_unique
        UNIQUE (partition, attribution_key)
    )
    """)
  end
end
