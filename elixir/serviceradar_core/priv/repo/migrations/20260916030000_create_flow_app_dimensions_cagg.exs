defmodule ServiceRadar.Repo.Migrations.CreateFlowAppDimensionsCagg do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @view "platform.ocsf_network_activity_hourly_app_dimensions"

  # serviceradar:allow-startup-maintenance
  # Create an empty aggregate, catalog policies and a durable bootstrap job.
  # The job initializes retained history one hour at a time outside startup.
  # Keep raw rule dimensions, including NULL, so current classification rules
  # can be applied after aggregation without freezing historical app labels.

  def up do
    if timescale_installed?() do
      execute("""
      CREATE MATERIALIZED VIEW IF NOT EXISTS #{@view}
      WITH (timescaledb.continuous, timescaledb.materialized_only = true) AS
      SELECT
        time_bucket('1 hour', time) AS bucket,
        partition,
        protocol_num,
        dst_endpoint_port,
        SUM(bytes_total::numeric *
          GREATEST(COALESCE(sampling_rate, 1), 1)::numeric)::bigint AS bytes_total,
        SUM(packets_total::numeric *
          GREATEST(COALESCE(sampling_rate, 1), 1)::numeric)::bigint AS packets_total,
        COUNT(*)::bigint AS flow_count
      FROM platform.ocsf_network_activity
      GROUP BY 1, 2, 3, 4
      WITH NO DATA
      """)

      execute("""
      CREATE INDEX IF NOT EXISTS idx_flow_app_dimensions_bucket
      ON #{@view} (bucket DESC)
      """)

      configure_policies()
      enqueue_bootstrap()
    end
  end

  def down do
    execute("""
    UPDATE platform.oban_jobs SET state = 'cancelled', cancelled_at = now()
    WHERE worker = 'ServiceRadar.Jobs.BootstrapFlowAppDimensionsWorker'
      AND state IN ('available', 'scheduled', 'executing', 'retryable')
    """)

    execute("DROP MATERIALIZED VIEW IF EXISTS #{@view}")
  end

  defp timescale_installed? do
    %{rows: [[installed]]} =
      repo().query!("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb')")

    installed
  end

  defp configure_policies do
    execute("""
    DO $$
    DECLARE ts_schema text;
    BEGIN
      SELECT n.nspname INTO ts_schema
        FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
       WHERE e.extname = 'timescaledb';
      IF ts_schema IS NULL THEN RETURN; END IF;

      -- Keep the refresh window inside raw retention; revisiting dropped raw
      -- hours would erase their materialized history. The two-hour span also
      -- satisfies Timescale's minimum complete-bucket refresh requirement.
      EXECUTE format(
        'SELECT %I.add_continuous_aggregate_policy(%L::regclass, '
        'start_offset => INTERVAL ''3 hours'', end_offset => INTERVAL ''1 hour'', '
        'schedule_interval => INTERVAL ''1 hour'', if_not_exists => true)',
        ts_schema, '#{@view}');

      EXECUTE format(
        'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''395 days'', '
        'if_not_exists => true)',
        ts_schema, '#{@view}');
    END;
    $$;
    """)
  end

  defp enqueue_bootstrap do
    execute("""
    INSERT INTO platform.oban_jobs (worker, queue, args, priority, max_attempts)
    SELECT 'ServiceRadar.Jobs.BootstrapFlowAppDimensionsWorker', 'maintenance', '{}'::jsonb, 3, 10
    WHERE NOT EXISTS (
      SELECT 1 FROM platform.oban_jobs
      WHERE worker = 'ServiceRadar.Jobs.BootstrapFlowAppDimensionsWorker'
        AND state IN ('available', 'scheduled', 'executing', 'retryable')
    )
    """)
  end
end
