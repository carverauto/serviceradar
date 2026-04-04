defmodule ServiceRadar.Repo.Migrations.DropNetflowMetricsLegacyTable do
  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("DROP TABLE IF EXISTS #{@prefix}.netflow_metrics")
  end

  def down do
    execute("""
    CREATE TABLE IF NOT EXISTS #{@prefix}.netflow_metrics (
      timestamp          TIMESTAMPTZ NOT NULL,
      src_ip             INET,
      dst_ip             INET,
      sampler_address    INET,
      src_port           INTEGER,
      dst_port           INTEGER,
      protocol           INTEGER,
      bytes_total        BIGINT,
      packets_total      BIGINT,
      as_path            INTEGER[],
      bgp_communities    INTEGER[],
      partition          TEXT NOT NULL DEFAULT 'default',
      metadata           JSONB,
      created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      bgp_observation_id UUID,
      PRIMARY KEY (timestamp, src_ip, dst_ip, protocol, src_port, dst_port)
    )
    """)

    maybe_create_hypertable("netflow_metrics", "timestamp")

    execute("""
    CREATE INDEX IF NOT EXISTS idx_netflow_metrics_as_path
    ON #{@prefix}.netflow_metrics USING GIN (as_path)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_netflow_metrics_bgp_communities
    ON #{@prefix}.netflow_metrics USING GIN (bgp_communities)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_netflow_metrics_timestamp
    ON #{@prefix}.netflow_metrics (timestamp DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_netflow_bgp_observation
    ON #{@prefix}.netflow_metrics (bgp_observation_id)
    """)
  end

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
            AND hypertable_schema = '#{@prefix}'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{@prefix}.#{table_name}',
            '#{time_column}'
          );
        END IF;
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create hypertable for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
