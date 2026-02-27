defmodule ServiceRadar.Repo.Migrations.FixTraceSummariesSchema do
  @moduledoc """
  Ensures otel_trace_summaries is a table (not a materialized view) in the
  platform schema with the refreshed_at column.

  Previous migration 20260210120000 used unqualified names, which on some
  deployments left a stale materialized view in the platform schema and/or
  created the table in public instead. This migration is fully idempotent
  and cleans up both scenarios.
  """
  use Ecto.Migration

  def up do
    schema = schema()
    # 1. Remove any stale copy in public (table or materialized view)
    execute("DROP TABLE IF EXISTS public.otel_trace_summaries CASCADE")
    execute("DROP MATERIALIZED VIEW IF EXISTS public.otel_trace_summaries CASCADE")

    # 2. If the platform copy is still a materialized view, replace it with a table
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        WHERE c.relname = 'otel_trace_summaries'
          AND n.nspname = '#{schema}'
          AND c.relkind = 'm'
      ) THEN
        DROP MATERIALIZED VIEW #{schema}.otel_trace_summaries CASCADE;
      END IF;
    END $$
    """)

    # 3. Create the table if it doesn't exist
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

    # 4. Add refreshed_at if the table already exists but is missing the column
    #    (handles case where table was created by the old unqualified migration)
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{schema}'
          AND table_name = 'otel_trace_summaries'
          AND column_name = 'refreshed_at'
      ) THEN
        ALTER TABLE #{schema}.otel_trace_summaries
          ADD COLUMN refreshed_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
      END IF;
    END $$
    """)

    # 5. Ensure indexes exist
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
    # Nothing to undo — this is a repair migration
    :ok
  end

  defp schema, do: prefix() || "platform"
end
