defmodule ServiceRadar.Repo.Migrations.ReconcileObservabilityRetentionChunks do
  @moduledoc """
  Aligns high-volume observability hypertable chunk intervals with retention.

  Retention can only reclaim a Timescale chunk when the entire chunk is older
  than the policy window. Keeping 7-day chunks on 1-3 day retention tables lets
  raw telemetry accumulate far beyond the configured TTL.
  """
  use Ecto.Migration

  @tables [
    {"otel_traces", "SERVICERADAR_OTEL_TRACES_RETENTION_DAYS", 3, "SERVICERADAR_OTEL_TRACES_CHUNK_INTERVAL_HOURS", 6},
    {"logs", "SERVICERADAR_LOGS_RETENTION_DAYS", 30, "SERVICERADAR_LOGS_CHUNK_INTERVAL_HOURS", 24},
    {"ocsf_network_activity", "SERVICERADAR_OCSF_NETWORK_ACTIVITY_RETENTION_DAYS", 90,
     "SERVICERADAR_OCSF_NETWORK_ACTIVITY_CHUNK_INTERVAL_HOURS", 24}
  ]

  def up do
    # serviceradar:allow-startup-maintenance - Timescale retention/chunk policy
    # reconciliation is metadata-only and idempotent for existing hypertables.
    Enum.each(@tables, fn {table_name, retention_env, retention_default, chunk_env, chunk_default} ->
      replace_retention_policy(
        table_name,
        configured_positive_integer(retention_env, retention_default)
      )

      set_chunk_interval(table_name, configured_positive_integer(chunk_env, chunk_default))
    end)
  end

  def down do
    replace_retention_policy("otel_traces", 3)
    set_chunk_interval("otel_traces", 168)

    replace_retention_policy("logs", 30)
    set_chunk_interval("logs", 168)

    replace_retention_policy("ocsf_network_activity", 90)
    set_chunk_interval("ocsf_network_activity", 168)
  end

  defp replace_retention_policy(table_name, retention_days) do
    execute("""
    DO $$
    DECLARE
      table_ident text;
      ts_schema text;
    BEGIN
      table_ident := format('%I.%I', '#{prefix() || "platform"}', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{prefix() || "platform"}'
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
      table_ident := format('%I.%I', '#{prefix() || "platform"}', '#{table_name}');

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{prefix() || "platform"}'
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
end
