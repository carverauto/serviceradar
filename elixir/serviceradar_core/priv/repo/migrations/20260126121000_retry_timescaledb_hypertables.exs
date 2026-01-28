defmodule ServiceRadar.Repo.Migrations.RetryTimescaledbHypertables do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
        -- Core time-series tables
        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'events'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.events'::regclass, 'event_timestamp', migrate_data => true, if_not_exists => true);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'logs'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.logs'::regclass, 'timestamp', migrate_data => true, if_not_exists => true);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'service_status'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.service_status'::regclass, 'timestamp', migrate_data => true, if_not_exists => true);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'otel_traces'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.otel_traces'::regclass, 'timestamp', migrate_data => true, if_not_exists => true);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'otel_metrics'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.otel_metrics'::regclass, 'timestamp', migrate_data => true, if_not_exists => true);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'timeseries_metrics'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.timeseries_metrics'::regclass, 'timestamp', migrate_data => true, if_not_exists => true);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'cpu_metrics'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.cpu_metrics'::regclass, 'timestamp', migrate_data => true, if_not_exists => true);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'disk_metrics'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.disk_metrics'::regclass, 'timestamp', migrate_data => true, if_not_exists => true);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'memory_metrics'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.memory_metrics'::regclass, 'timestamp', migrate_data => true, if_not_exists => true);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'process_metrics'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.process_metrics'::regclass, 'timestamp', migrate_data => true, if_not_exists => true);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'device_updates'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.device_updates'::regclass, 'observed_at', migrate_data => true, if_not_exists => true);
        END IF;

        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'otel_metrics_hourly_stats'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.otel_metrics_hourly_stats'::regclass, 'bucket', migrate_data => true, if_not_exists => true);
        END IF;

        -- Interface observations retention policy (3 days)
        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix()}' AND hypertable_name = 'discovered_interfaces'
        ) THEN
          PERFORM create_hypertable('#{prefix()}.discovered_interfaces'::regclass, 'timestamp', migrate_data => true, if_not_exists => true);
        END IF;

        PERFORM add_retention_policy(
          '#{prefix()}.discovered_interfaces'::regclass,
          INTERVAL '3 days',
          if_not_exists => true
        );
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
