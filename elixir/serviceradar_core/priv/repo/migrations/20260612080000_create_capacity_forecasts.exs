defmodule ServiceRadar.Repo.Migrations.CreateCapacityForecasts do
  @moduledoc """
  Creates the raw-managed TimescaleDB store for capacity forecast snapshots.
  """
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.capacity_forecasts (
      forecasted_at             TIMESTAMPTZ NOT NULL,
      resource_key              TEXT NOT NULL,
      resource_type             TEXT NOT NULL,
      resource_id               TEXT NOT NULL,
      resource_label            TEXT,
      metric_class              TEXT NOT NULL,
      metric_name               TEXT NOT NULL,
      horizon_seconds           BIGINT NOT NULL CHECK (horizon_seconds > 0),
      horizon_ends_at           TIMESTAMPTZ NOT NULL,
      window_started_at         TIMESTAMPTZ,
      window_ended_at           TIMESTAMPTZ,
      sample_count              INTEGER NOT NULL DEFAULT 0 CHECK (sample_count >= 0),
      model                     TEXT NOT NULL DEFAULT 'linear',
      status                    TEXT NOT NULL DEFAULT 'projected',
      skip_reason               TEXT,
      current_value             DOUBLE PRECISION,
      slope_per_second          DOUBLE PRECISION,
      intercept                 DOUBLE PRECISION,
      projected_value           DOUBLE PRECISION,
      projected_exhaustion_at   TIMESTAMPTZ,
      exhaustion_threshold      DOUBLE PRECISION,
      confidence                DOUBLE PRECISION CHECK (confidence IS NULL OR (confidence >= 0.0 AND confidence <= 1.0)),
      lower_bound               DOUBLE PRECISION,
      upper_bound               DOUBLE PRECISION,
      metadata                  JSONB NOT NULL DEFAULT '{}'::jsonb,
      inserted_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
      PRIMARY KEY (forecasted_at, resource_key, metric_name, horizon_seconds),
      CHECK (status IN ('projected', 'skipped')),
      CHECK (
        (status = 'skipped' AND skip_reason IS NOT NULL)
        OR
        (
          status = 'projected'
          AND slope_per_second IS NOT NULL
          AND projected_value IS NOT NULL
          AND confidence IS NOT NULL
        )
      )
    )
    """)

    maybe_create_hypertable()

    execute("""
    CREATE INDEX IF NOT EXISTS idx_capacity_forecasts_resource_time
    ON #{schema()}.capacity_forecasts (resource_type, resource_id, metric_name, forecasted_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_capacity_forecasts_class_time
    ON #{schema()}.capacity_forecasts (metric_class, forecasted_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_capacity_forecasts_exhaustion
    ON #{schema()}.capacity_forecasts (projected_exhaustion_at)
    WHERE projected_exhaustion_at IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_capacity_forecasts_status_time
    ON #{schema()}.capacity_forecasts (status, forecasted_at DESC)
    """)
  end

  def down do
    execute("DROP TABLE IF EXISTS #{schema()}.capacity_forecasts CASCADE")
  end

  defp maybe_create_hypertable do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      table_ident text;
    BEGIN
      table_ident := format('%I.%I', '#{schema()}', 'capacity_forecasts');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RAISE NOTICE 'TimescaleDB not available; capacity_forecasts stays a plain table';
        RETURN;
      END IF;

      EXECUTE format(
        'SELECT %I.create_hypertable(%L::regclass, %L::name, if_not_exists => true, migrate_data => false)',
        ts_schema,
        table_ident,
        'forecasted_at'
      );
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not configure capacity_forecasts hypertable: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp schema, do: prefix() || "platform"
end
