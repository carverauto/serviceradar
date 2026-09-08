defmodule ServiceRadar.Repo.Migrations.UpdateObservabilityRetentionPolicies do
  @moduledoc """
  Tightens high-volume observability retention policies.
  """
  use Ecto.Migration

  @policy_updates [
    {"otel_traces", "3 days"},
    {"ocsf_network_activity", "90 days"}
  ]

  def up do
    Enum.each(@policy_updates, fn {table_name, interval} ->
      replace_retention_policy(table_name, interval)
    end)
  end

  def down do
    replace_retention_policy("otel_traces", "30 days")
    replace_retention_policy("ocsf_network_activity", "7 days")
  end

  defp replace_retention_policy(table_name, interval) do
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
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''#{interval}'', if_not_exists => true)',
          ts_schema,
          table_ident
        );

        RAISE NOTICE 'Set #{interval} retention policy on #{table_name}';
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
end
