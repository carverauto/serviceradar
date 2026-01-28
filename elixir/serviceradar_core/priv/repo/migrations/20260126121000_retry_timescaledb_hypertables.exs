defmodule ServiceRadar.Repo.Migrations.RetryTimescaledbHypertables do
  use Ecto.Migration

  def up do
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
        -- Core time-series tables
        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'events'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'events'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.events',
            'event_timestamp'
          );
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'logs'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'logs'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.logs',
            'timestamp'
          );
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'service_status'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'service_status'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.service_status',
            'timestamp'
          );
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'otel_traces'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'otel_traces'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.otel_traces',
            'timestamp'
          );
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'otel_metrics'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'otel_metrics'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.otel_metrics',
            'timestamp'
          );
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'timeseries_metrics'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'timeseries_metrics'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.timeseries_metrics',
            'timestamp'
          );
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'cpu_metrics'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'cpu_metrics'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.cpu_metrics',
            'timestamp'
          );
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'disk_metrics'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'disk_metrics'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.disk_metrics',
            'timestamp'
          );
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'memory_metrics'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'memory_metrics'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.memory_metrics',
            'timestamp'
          );
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'process_metrics'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'process_metrics'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.process_metrics',
            'timestamp'
          );
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'device_updates'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'device_updates'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.device_updates',
            'observed_at'
          );
        END IF;

        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'otel_metrics_hourly_stats'
        ) AND NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'otel_metrics_hourly_stats'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix()}.otel_metrics_hourly_stats',
            'bucket'
          );
        END IF;

        -- Interface observations retention policy (3 days)
        IF EXISTS (
          SELECT 1 FROM pg_tables
          WHERE schemaname = '#{prefix()}' AND tablename = 'discovered_interfaces'
        ) THEN
          IF NOT EXISTS (
            SELECT 1 FROM timescaledb_information.hypertables
            WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'discovered_interfaces'
          ) THEN
            EXECUTE format(
              'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
              ts_schema,
              '#{prefix()}.discovered_interfaces',
              'timestamp'
            );
          END IF;

          EXECUTE format(
            'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''3 days'', if_not_exists => true)',
            ts_schema,
            '#{prefix()}.discovered_interfaces'
          );
        END IF;
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not ensure hypertables: %', SQLERRM;
    END;
    $$;
    """)
  end

  def down do
    :ok
  end
end
