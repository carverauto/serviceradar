defmodule ServiceRadar.Repo.Migrations.AddTracesStats5mCagg do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @view "platform.traces_stats_5m"
  @refresh_start_offset "7 days"
  @refresh_end_offset "5 minutes"
  @refresh_interval "5 minutes"
  @retention_interval "14 days"

  def up do
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('5 minutes', timestamp) AS bucket,
      service_name,
      COUNT(*)::bigint AS total_count,
      COUNT(*) FILTER (WHERE status_code = 2)::bigint AS error_count,
      AVG(((end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0))::float8 AS avg_duration_ms,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY ((end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0))::float8 AS p95_duration_ms
    FROM platform.otel_traces
    WHERE parent_span_id IS NULL OR parent_span_id = ''
    GROUP BY 1, 2
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_traces_stats_5m_bucket_service
    ON #{@view} (bucket DESC, service_name)
    """)

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

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
          'start_offset => INTERVAL ''#{@refresh_start_offset}'', '
          'end_offset => INTERVAL ''#{@refresh_end_offset}'', '
          'schedule_interval => INTERVAL ''#{@refresh_interval}'')',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{@retention_interval}'', if_not_exists => true)',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;

      BEGIN
        EXECUTE format(
          'CALL %I.refresh_continuous_aggregate(%L::regclass, NOW() - INTERVAL ''#{@refresh_start_offset}'', NOW())',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;
    END;
    $$;
    """)
  end

  def down do
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

      IF ts_schema IS NULL THEN
        RETURN;
      END IF;

      BEGIN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;

      BEGIN
        EXECUTE format(
          'SELECT %I.remove_continuous_aggregate_policy(%L::regclass)',
          ts_schema,
          '#{@view}'
        );
      EXCEPTION
        WHEN others THEN
          NULL;
      END;
    END;
    $$;
    """)

    execute("DROP MATERIALIZED VIEW IF EXISTS #{@view}")
  end
end
