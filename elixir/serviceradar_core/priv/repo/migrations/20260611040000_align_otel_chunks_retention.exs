defmodule ServiceRadar.Repo.Migrations.AlignOtelChunksRetention do
  @moduledoc """
  Aligns OTel hypertable chunk intervals with their retention windows so the
  Timescale retention policies actually drop chunks:

  - `otel_traces` chunks shrink to 1 hour (3-day retention default)
  - `logs` chunks shrink to 6 hours when currently larger (30-day retention)
  - retention policies are (re)applied from the runtime configuration
    defaults for `otel_traces`, `logs`, and `otel_metrics`

  Also rebuilds the `traces_stats_5m` continuous aggregate: its previous
  definition detected root spans via `parent_span_id IS NULL OR
  parent_span_id = ''`; the canonical id contract stores NULL for absent
  parents, so the predicate becomes `parent_span_id IS NULL`.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @view "platform.traces_stats_5m"
  @refresh_start_offset "7 days"
  @refresh_end_offset "5 minutes"
  @refresh_interval "5 minutes"
  @retention_interval "14 days"

  def up do
    # serviceradar:allow-startup-maintenance - Timescale retention/chunk policy
    # reconciliation is metadata-only and idempotent for existing hypertables.
    replace_retention_policy(
      "otel_traces",
      configured_positive_integer("SERVICERADAR_OTEL_TRACES_RETENTION_DAYS", 3)
    )

    set_chunk_interval(
      "otel_traces",
      configured_positive_integer("SERVICERADAR_OTEL_TRACES_CHUNK_INTERVAL_HOURS", 1)
    )

    replace_retention_policy(
      "logs",
      configured_positive_integer("SERVICERADAR_LOGS_RETENTION_DAYS", 30)
    )

    shrink_chunk_interval(
      "logs",
      configured_positive_integer("SERVICERADAR_LOGS_CHUNK_INTERVAL_HOURS", 6)
    )

    replace_retention_policy(
      "otel_metrics",
      configured_positive_integer("SERVICERADAR_OTEL_METRICS_RETENTION_DAYS", 30)
    )

    rebuild_traces_stats_cagg("parent_span_id IS NULL")
  end

  def down do
    replace_retention_policy("otel_traces", 3)
    set_chunk_interval("otel_traces", 6)

    rebuild_traces_stats_cagg("parent_span_id IS NULL OR parent_span_id = ''")
  end

  defp rebuild_traces_stats_cagg(root_predicate) do
    execute(remove_cagg_policies_sql())
    execute("DROP MATERIALIZED VIEW IF EXISTS #{@view} CASCADE")
    execute(create_cagg_sql(root_predicate))

    execute(
      "CREATE INDEX IF NOT EXISTS idx_traces_stats_5m_bucket_service ON #{@view} (bucket DESC, service_name)"
    )

    execute(add_cagg_policies_sql())
  end

  defp create_cagg_sql(root_predicate) do
    """
    CREATE MATERIALIZED VIEW #{@view}
    WITH (timescaledb.continuous) AS
    SELECT
      time_bucket('5 minutes', timestamp) AS bucket,
      service_name,
      COUNT(*)::bigint AS total_count,
      COUNT(*) FILTER (WHERE status_code = 2)::bigint AS error_count,
      AVG(((end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0))::float8 AS avg_duration_ms,
      PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY ((end_time_unix_nano - start_time_unix_nano)::float8 / 1000000.0))::float8 AS p95_duration_ms
    FROM platform.otel_traces
    WHERE #{root_predicate}
    GROUP BY 1, 2
    WITH NO DATA
    """
  end

  defp remove_cagg_policies_sql do
    """
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
    """
  end

  defp add_cagg_policies_sql do
    """
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
    """
  end

  defp replace_retention_policy(table_name, retention_days) do
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
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          table_ident
        );

        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{retention_days} days'', if_not_exists => true)',
          ts_schema,
          table_ident
        );

        RAISE NOTICE 'Set #{retention_days} day retention policy on #{table_name}';
      ELSE
        RAISE NOTICE 'Skipping retention policy for #{table_name} - not a hypertable or TimescaleDB not available';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not update retention policy for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp set_chunk_interval(table_name, chunk_hours) do
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
          'SELECT %I.set_chunk_time_interval(%L::regclass, INTERVAL ''#{chunk_hours} hours'')',
          ts_schema,
          table_ident
        );

        RAISE NOTICE 'Set #{chunk_hours} hour chunk interval on #{table_name}';
      ELSE
        RAISE NOTICE 'Skipping chunk interval for #{table_name} - not a hypertable or TimescaleDB not available';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not update chunk interval for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  # Shrink-only variant: leaves the chunk interval untouched when it is
  # already at or below the target.
  defp shrink_chunk_interval(table_name, chunk_hours) do
    execute("""
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
      current_interval interval;
    BEGIN
      table_ident := format('%I.%I', '#{schema()}', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL
         OR NOT EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{schema()}'
             AND hypertable_name = '#{table_name}'
         ) THEN
        RAISE NOTICE 'Skipping chunk interval for #{table_name} - not a hypertable or TimescaleDB not available';
        RETURN;
      END IF;

      SELECT time_interval
      INTO current_interval
      FROM timescaledb_information.dimensions
      WHERE hypertable_schema = '#{schema()}'
        AND hypertable_name = '#{table_name}'
        AND time_interval IS NOT NULL
      LIMIT 1;

      IF current_interval IS NOT NULL AND current_interval > INTERVAL '#{chunk_hours} hours' THEN
        EXECUTE format(
          'SELECT %I.set_chunk_time_interval(%L::regclass, INTERVAL ''#{chunk_hours} hours'')',
          ts_schema,
          table_ident
        );

        RAISE NOTICE 'Shrunk chunk interval on #{table_name} to #{chunk_hours} hours';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not update chunk interval for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp configured_positive_integer(env_name, default) do
    case System.get_env(env_name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 -> int
          _ -> default
        end
    end
  end

  defp schema, do: prefix() || "platform"
end
