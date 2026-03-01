defmodule ServiceRadar.Repo.Migrations.CreateMtrTracesHypertables do
  @moduledoc """
  Creates mtr_traces and mtr_hops hypertables for storing MTR (My Traceroute)
  diagnostic results collected by serviceradar-agent.

  mtr_traces: One row per trace execution (target, protocol, reach status).
  mtr_hops: One row per hop in a trace (per-hop latency, loss, ASN, MPLS).

  Both are TimescaleDB hypertables with 30-day retention by default.
  """
  use Ecto.Migration

  @traces_table "mtr_traces"
  @hops_table "mtr_hops"
  @retention_interval "30 days"

  def up do
    create_traces_table()
    create_hops_table()
  end

  def down do
    remove_retention_policy(@hops_table)
    remove_retention_policy(@traces_table)

    execute("DROP INDEX IF EXISTS #{schema()}.idx_mtr_hops_trace_id")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_mtr_hops_addr")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_mtr_hops_asn")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_mtr_hops_time")
    execute("DROP TABLE IF EXISTS #{schema()}.#{@hops_table}")

    execute("DROP INDEX IF EXISTS #{schema()}.idx_mtr_traces_agent_target")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_mtr_traces_device_id")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_mtr_traces_target_ip")
    execute("DROP INDEX IF EXISTS #{schema()}.idx_mtr_traces_time")
    execute("DROP TABLE IF EXISTS #{schema()}.#{@traces_table}")
  end

  defp create_traces_table do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.#{@traces_table} (
      id              UUID        NOT NULL,
      time            TIMESTAMPTZ NOT NULL,
      agent_id        TEXT        NOT NULL,
      gateway_id      TEXT,
      check_id        TEXT,
      check_name      TEXT,
      device_id       TEXT,
      target          TEXT        NOT NULL,
      target_ip       TEXT        NOT NULL,
      target_reached  BOOLEAN     NOT NULL DEFAULT false,
      total_hops      INTEGER     NOT NULL DEFAULT 0,
      protocol        TEXT        NOT NULL DEFAULT 'icmp',
      ip_version      INTEGER     NOT NULL DEFAULT 4,
      packet_size     INTEGER,
      partition       TEXT,
      error           TEXT,
      created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (time, id)
    )
    """)

    maybe_create_hypertable(@traces_table, "time")

    execute("""
    CREATE INDEX IF NOT EXISTS idx_mtr_traces_time
      ON #{schema()}.#{@traces_table} (time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_mtr_traces_target_ip
      ON #{schema()}.#{@traces_table} (target_ip, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_mtr_traces_device_id
      ON #{schema()}.#{@traces_table} (device_id, time DESC)
      WHERE device_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_mtr_traces_agent_target
      ON #{schema()}.#{@traces_table} (agent_id, target, time DESC)
    """)

    add_retention_policy(@traces_table, @retention_interval)

    execute("""
    COMMENT ON TABLE #{schema()}.#{@traces_table} IS
      'MTR trace executions with per-target reachability and path metadata'
    """)
  end

  defp create_hops_table do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.#{@hops_table} (
      id              UUID        NOT NULL,
      time            TIMESTAMPTZ NOT NULL,
      trace_id        UUID        NOT NULL,
      hop_number      INTEGER     NOT NULL,
      addr            TEXT,
      hostname        TEXT,
      ecmp_addrs      TEXT[],
      asn             INTEGER,
      asn_org         TEXT,
      mpls_labels     JSONB,
      sent            INTEGER     NOT NULL DEFAULT 0,
      received        INTEGER     NOT NULL DEFAULT 0,
      loss_pct        DOUBLE PRECISION NOT NULL DEFAULT 0.0,
      last_us         BIGINT,
      avg_us          BIGINT,
      min_us          BIGINT,
      max_us          BIGINT,
      stddev_us       BIGINT,
      jitter_us       BIGINT,
      jitter_worst_us BIGINT,
      jitter_interarrival_us BIGINT,
      created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (time, id)
    )
    """)

    maybe_create_hypertable(@hops_table, "time")

    execute("""
    CREATE INDEX IF NOT EXISTS idx_mtr_hops_time
      ON #{schema()}.#{@hops_table} (time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_mtr_hops_trace_id
      ON #{schema()}.#{@hops_table} (trace_id, hop_number)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_mtr_hops_addr
      ON #{schema()}.#{@hops_table} (addr, time DESC)
      WHERE addr IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_mtr_hops_asn
      ON #{schema()}.#{@hops_table} (asn, time DESC)
      WHERE asn IS NOT NULL
    """)

    add_retention_policy(@hops_table, @retention_interval)

    execute("""
    COMMENT ON TABLE #{schema()}.#{@hops_table} IS
      'Per-hop MTR statistics with latency, loss, MPLS labels, and ASN enrichment'
    """)
  end

  defp schema, do: prefix() || "platform"

  defp maybe_create_hypertable(table_name, time_column) do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL THEN
        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_name = '#{table_name}'
            AND hypertable_schema = '#{schema()}'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{schema()}.#{table_name}',
            '#{time_column}'
          );
          RAISE NOTICE 'Created hypertable for #{table_name}';
        END IF;
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create hypertable for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp add_retention_policy(table_name, interval) do
    execute("""
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', '#{schema()}', '#{table_name}');
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{schema()}'
             AND hypertable_name = '#{table_name}'
         ) THEN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{interval}'', if_not_exists => true)',
          ts_schema,
          table_ident
        );
        RAISE NOTICE 'Added #{interval} retention policy to #{table_name}';
      ELSE
        RAISE NOTICE 'Skipping retention policy for #{table_name} - not a hypertable or TimescaleDB not available';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not add retention policy to #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp remove_retention_policy(table_name) do
    execute("""
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', '#{schema()}', '#{table_name}');
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL THEN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );
        RAISE NOTICE 'Removed retention policy from #{table_name}';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not remove retention policy from #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
