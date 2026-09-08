defmodule ServiceRadar.Repo.Migrations.AddOtelSpanFidelityColumns do
  @moduledoc """
  Adds span-fidelity columns to `platform.otel_traces` and root
  namespace/environment columns to `platform.otel_trace_summaries`, then
  rebuilds the `spans_red_1h` continuous aggregate grouped by
  (bucket, service_name, service_namespace, deployment_environment).

  Column contract (shared with the Go gateway and rust/srql — do not
  deviate):

  - otel_traces: trace_state TEXT NULL, scope_attributes TEXT NULL,
    dropped_attributes_count/dropped_events_count/dropped_links_count
    INTEGER NOT NULL DEFAULT 0, service_namespace/deployment_environment
    TEXT NOT NULL DEFAULT ''
  - otel_trace_summaries: root_service_namespace/deployment_environment
    TEXT NOT NULL DEFAULT ''
  - spans_red_1h: bucket, service_name, service_namespace,
    deployment_environment, total_count, error_count, slow_count,
    avg_duration_ms, p50_duration_ms, p95_duration_ms, max_duration_ms
  """
  use Ecto.Migration

  # serviceradar:allow-startup-maintenance - rebuilds the spans_red_1h CAGG: empty source on
  # first boot makes the drop/recreate/refresh no-ops, bounded to the backfill window, with the
  # continuous-aggregate/retention policies only registering background jobs.

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
    ALTER TABLE #{schema()}.otel_traces
      ADD COLUMN IF NOT EXISTS trace_state TEXT NULL,
      ADD COLUMN IF NOT EXISTS scope_attributes TEXT NULL,
      ADD COLUMN IF NOT EXISTS dropped_attributes_count INTEGER NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS dropped_events_count INTEGER NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS dropped_links_count INTEGER NOT NULL DEFAULT 0,
      ADD COLUMN IF NOT EXISTS service_namespace TEXT NOT NULL DEFAULT '',
      ADD COLUMN IF NOT EXISTS deployment_environment TEXT NOT NULL DEFAULT ''
    """)

    execute("""
    ALTER TABLE #{schema()}.otel_trace_summaries
      ADD COLUMN IF NOT EXISTS root_service_namespace TEXT NOT NULL DEFAULT '',
      ADD COLUMN IF NOT EXISTS deployment_environment TEXT NOT NULL DEFAULT ''
    """)

    drop_cagg()

    create_cagg(
      """
      COALESCE(service_namespace, '') AS service_namespace,
      COALESCE(deployment_environment, '') AS deployment_environment,
      """,
      "GROUP BY 1, 2, 3, 4",
      "(bucket DESC, service_name, service_namespace, deployment_environment)"
    )
  end

  def down do
    drop_cagg()

    execute("""
    ALTER TABLE #{schema()}.otel_trace_summaries
      DROP COLUMN IF EXISTS root_service_namespace,
      DROP COLUMN IF EXISTS deployment_environment
    """)

    execute("""
    ALTER TABLE #{schema()}.otel_traces
      DROP COLUMN IF EXISTS trace_state,
      DROP COLUMN IF EXISTS scope_attributes,
      DROP COLUMN IF EXISTS dropped_attributes_count,
      DROP COLUMN IF EXISTS dropped_events_count,
      DROP COLUMN IF EXISTS dropped_links_count,
      DROP COLUMN IF EXISTS service_namespace,
      DROP COLUMN IF EXISTS deployment_environment
    """)

    # Restore the original (bucket, service_name) aggregate.
    create_cagg("", "GROUP BY 1, 2", "(bucket DESC, service_name)")
  end

  defp create_cagg(extra_group_columns, group_by, service_index_columns) do
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{@view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('1 hour', timestamp) AS bucket,
      COALESCE(service_name, '') AS service_name,
      #{extra_group_columns}
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
    #{group_by}
    WITH NO DATA
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_spans_red_1h_bucket_service
    ON #{@view} #{service_index_columns}
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

  defp drop_cagg do
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

  defp schema, do: prefix() || "platform"
end
