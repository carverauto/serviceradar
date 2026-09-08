defmodule ServiceRadar.Repo.Migrations.ReplaceOtelMetricsHourlyStatsWithCagg do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @view "platform.otel_metrics_hourly_stats"
  @refresh_start_offset "32 days"
  @refresh_end_offset "10 minutes"
  @refresh_interval "10 minutes"
  @retention_interval "90 days"
  @backfill_interval "32 days"

  def up do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      relation_kind "char";
      is_cagg boolean := false;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RAISE NOTICE 'TimescaleDB extension not available, skipping #{@view} replacement';
        RETURN;
      END IF;

      SELECT EXISTS (
        SELECT 1
        FROM timescaledb_information.continuous_aggregates
        WHERE view_schema = 'platform'
          AND view_name = 'otel_metrics_hourly_stats'
      )
      INTO is_cagg;

      SELECT c.relkind
      INTO relation_kind
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'platform'
        AND c.relname = 'otel_metrics_hourly_stats';

      IF relation_kind IS NOT NULL AND NOT is_cagg THEN
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

        IF relation_kind IN ('r', 'p') THEN
          EXECUTE 'DROP TABLE IF EXISTS #{@view} CASCADE';
        ELSIF relation_kind = 'm' THEN
          EXECUTE 'DROP MATERIALIZED VIEW IF EXISTS #{@view} CASCADE';
        ELSIF relation_kind = 'v' THEN
          EXECUTE 'DROP VIEW IF EXISTS #{@view} CASCADE';
        END IF;
      END IF;
    END;
    $$;
    """)

    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', timestamp) AS bucket,
      COALESCE(service_name, '') AS service_name,
      COUNT(*)::bigint AS total_count,
      COUNT(*) FILTER (
        WHERE
          COALESCE(level, '') IN ('error', 'ERROR')
          OR COALESCE(http_status_code, '') LIKE '4%'
          OR COALESCE(http_status_code, '') LIKE '5%'
          OR (COALESCE(grpc_status_code, '') <> '' AND COALESCE(grpc_status_code, '') <> '0')
      )::bigint AS error_count,
      COUNT(*) FILTER (WHERE is_slow IS TRUE)::bigint AS slow_count,
      COUNT(*) FILTER (WHERE COALESCE(http_status_code, '') LIKE '4%')::bigint AS http_4xx_count,
      COUNT(*) FILTER (WHERE COALESCE(http_status_code, '') LIKE '5%')::bigint AS http_5xx_count,
      COUNT(*) FILTER (
        WHERE COALESCE(grpc_status_code, '') <> '' AND COALESCE(grpc_status_code, '') <> '0'
      )::bigint AS grpc_error_count,
      AVG(duration_ms)::float8 AS avg_duration_ms,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY duration_ms)
        FILTER (WHERE duration_ms IS NOT NULL)::float8 AS p95_duration_ms,
      MAX(duration_ms)::float8 AS max_duration_ms
    FROM platform.otel_metrics
    GROUP BY 1, 2
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_otel_metrics_hourly_stats_bucket_service
    ON #{@view} (bucket DESC, service_name)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_otel_metrics_hourly_stats_bucket
    ON #{@view} (bucket DESC)
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
          'CALL %I.refresh_continuous_aggregate(%L::regclass, NOW() - INTERVAL ''#{@backfill_interval}'', NOW())',
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

      IF ts_schema IS NOT NULL THEN
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
      END IF;
    END;
    $$;
    """)

    execute("DROP MATERIALIZED VIEW IF EXISTS #{@view}")

    execute("""
    CREATE TABLE IF NOT EXISTS #{@view} (
      bucket           TIMESTAMPTZ NOT NULL,
      service_name     TEXT        NOT NULL DEFAULT '',
      total_count      BIGINT      NOT NULL DEFAULT 0,
      error_count      BIGINT      NOT NULL DEFAULT 0,
      slow_count       BIGINT      NOT NULL DEFAULT 0,
      http_4xx_count   BIGINT      NOT NULL DEFAULT 0,
      http_5xx_count   BIGINT      NOT NULL DEFAULT 0,
      grpc_error_count BIGINT      NOT NULL DEFAULT 0,
      avg_duration_ms  FLOAT8      NOT NULL DEFAULT 0,
      p95_duration_ms  FLOAT8,
      max_duration_ms  FLOAT8,
      PRIMARY KEY (bucket, service_name)
    )
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

      IF EXISTS (
        SELECT 1
        FROM pg_tables
        WHERE schemaname = 'platform'
          AND tablename = 'otel_metrics_hourly_stats'
      ) AND NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'platform'
          AND hypertable_name = 'otel_metrics_hourly_stats'
      ) THEN
        EXECUTE format(
          'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
          ts_schema,
          '#{@view}',
          'bucket'
        );
      END IF;

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
    END;
    $$;
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_otel_metrics_hourly_stats_bucket
    ON #{@view} (bucket DESC)
    """)
  end
end
