defmodule ServiceRadar.Repo.Migrations.CreateSpansRed1hCagg do
  @moduledoc """
  Continuous aggregate of span RED metrics (rate/errors/duration) over the
  FULL span stream (`platform.otel_traces`), replacing slow-sample-biased
  stats as the source for traces/metrics stat cards.

  Column contract (shared with rust/srql and web-ng — do not deviate):
  bucket, service_name, total_count, error_count, slow_count,
  avg_duration_ms, p50_duration_ms, p95_duration_ms, max_duration_ms.
  """
  use Ecto.Migration

  # serviceradar:allow-startup-maintenance - spans RED CAGG: the source span stream is empty on
  # first boot so the create/refresh are no-ops; the one-time refresh is bounded to the backfill
  # window and the continuous-aggregate/retention policies only register background jobs.

  @disable_ddl_transaction true
  @disable_migration_lock true

  @view "platform.spans_red_1h"
  @refresh_start_offset "32 days"
  @refresh_end_offset "10 minutes"
  @refresh_interval "10 minutes"
  @retention_interval "90 days"
  @backfill_interval "32 days"
  @duration_ms "((end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0)"

  def up do
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', timestamp) AS bucket,
      COALESCE(service_name, '') AS service_name,
      COUNT(*)::bigint AS total_count,
      COUNT(*) FILTER (WHERE status_code = 2)::bigint AS error_count,
      COUNT(*) FILTER (WHERE #{@duration_ms} > 100)::bigint AS slow_count,
      AVG(#{@duration_ms})::float8 AS avg_duration_ms,
      PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY #{@duration_ms})
        FILTER (WHERE #{@duration_ms} IS NOT NULL)::float8 AS p50_duration_ms,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY #{@duration_ms})
        FILTER (WHERE #{@duration_ms} IS NOT NULL)::float8 AS p95_duration_ms,
      MAX(#{@duration_ms})::float8 AS max_duration_ms
    FROM platform.otel_traces
    GROUP BY 1, 2
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_spans_red_1h_bucket_service
    ON #{@view} (bucket DESC, service_name)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_spans_red_1h_bucket
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
  end
end
