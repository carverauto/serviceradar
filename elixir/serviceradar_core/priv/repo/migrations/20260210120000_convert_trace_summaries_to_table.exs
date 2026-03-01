defmodule ServiceRadar.Repo.Migrations.ConvertTraceSummariesToTable do
  @moduledoc """
  Converts otel_trace_summaries from a materialized view to a regular table.

  The materialized view required a full rescan of all otel_traces (7 days) on every
  REFRESH MATERIALIZED VIEW call, which timed out under real trace volume.

  A regular table allows incremental upserts — the worker only processes trace_ids
  with new spans since the last run, turning O(all_data_7_days) into O(new_data).
  """
  use Ecto.Migration

  def up do
    schema = schema()

    # Drop whichever object currently exists in platform (materialized view or table).
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '#{schema}' AND c.relname = 'otel_trace_summaries' AND c.relkind = 'm'
      ) THEN
        EXECUTE 'DROP MATERIALIZED VIEW #{schema}.otel_trace_summaries CASCADE';
      ELSIF EXISTS (
        SELECT 1
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '#{schema}' AND c.relname = 'otel_trace_summaries' AND c.relkind = 'r'
      ) THEN
        EXECUTE 'DROP TABLE #{schema}.otel_trace_summaries CASCADE';
      END IF;
    END
    $$;
    """)

    # Also clean up any stale copy that ended up in public
    execute("DROP MATERIALIZED VIEW IF EXISTS public.otel_trace_summaries CASCADE")
    execute("DROP TABLE IF EXISTS public.otel_trace_summaries CASCADE")

    # Create regular table with same schema + refreshed_at for incremental upserts
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema}.otel_trace_summaries (
      trace_id         TEXT PRIMARY KEY,
      timestamp        TIMESTAMPTZ,
      root_span_id     TEXT,
      root_span_name   TEXT,
      root_service_name TEXT,
      root_span_kind   INT,
      start_time_unix_nano BIGINT,
      end_time_unix_nano   BIGINT,
      duration_ms      FLOAT8,
      status_code      INT,
      status_message   TEXT,
      service_set      TEXT[],
      span_count       BIGINT,
      error_count      BIGINT,
      refreshed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """)

    # Same indexes as before (minus the unique one — PRIMARY KEY covers that)
    execute("""
    CREATE INDEX IF NOT EXISTS idx_trace_summaries_timestamp
    ON #{schema}.otel_trace_summaries (timestamp DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trace_summaries_service_timestamp
    ON #{schema}.otel_trace_summaries (root_service_name, timestamp DESC)
    """)
  end

  def down do
    schema = schema()

    # Drop either form before recreating the materialized view.
    execute("DROP TABLE IF EXISTS #{schema}.otel_trace_summaries CASCADE")
    execute("DROP MATERIALIZED VIEW IF EXISTS #{schema}.otel_trace_summaries CASCADE")

    # Recreate the materialized view
    execute("""
    CREATE MATERIALIZED VIEW IF NOT EXISTS #{schema}.otel_trace_summaries AS
    SELECT
      trace_id,
      max(timestamp) AS timestamp,
      max(span_id) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS root_span_id,
      max(name) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS root_span_name,
      max(service_name) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS root_service_name,
      max(kind) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS root_span_kind,
      min(start_time_unix_nano) AS start_time_unix_nano,
      max(end_time_unix_nano) AS end_time_unix_nano,
      (max(end_time_unix_nano) - min(start_time_unix_nano))::float8 / 1000000.0 AS duration_ms,
      max(status_code) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS status_code,
      max(status_message) FILTER (WHERE parent_span_id IS NULL OR parent_span_id = '') AS status_message,
      array_agg(DISTINCT service_name) FILTER (WHERE service_name IS NOT NULL) AS service_set,
      count(*) AS span_count,
      count(*) FILTER (WHERE status_code IS NOT NULL AND status_code != 1) AS error_count
    FROM #{schema}.otel_traces
    WHERE timestamp >= NOW() - INTERVAL '7 days'
      AND trace_id IS NOT NULL
    GROUP BY trace_id
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS idx_trace_summaries_trace_id
    ON #{schema}.otel_trace_summaries (trace_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trace_summaries_timestamp
    ON #{schema}.otel_trace_summaries (timestamp DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_trace_summaries_service_timestamp
    ON #{schema}.otel_trace_summaries (root_service_name, timestamp DESC)
    """)

    execute("REFRESH MATERIALIZED VIEW #{schema}.otel_trace_summaries")
  end

  defp schema, do: prefix() || "platform"
end
