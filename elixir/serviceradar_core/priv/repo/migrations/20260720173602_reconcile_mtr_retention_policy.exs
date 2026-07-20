defmodule ServiceRadar.Repo.Migrations.ReconcileMtrRetentionPolicy do
  @moduledoc """
  Rebuilds MTR's Timescale configuration during migrations so bootstrap does
  not depend on a delayed application seeder.
  """

  use Ecto.Migration

  @default_retention_days 30

  def up do
    ensure_mtr_settings()
    reconcile_retention_policies()
  end

  # MTR history already had a retention policy before this repair migration.
  # Keep the reconciled policy and seeded settings when rolling back so a
  # rollback cannot leave history unbounded.
  def down, do: :ok

  defp ensure_mtr_settings do
    execute("""
    INSERT INTO platform.mtr_settings
      (mtr_retention_days, mtr_default_history_window, mtr_history_page_size_default, inserted_at, updated_at)
    SELECT
      #{configured_retention_days()},
      'last_30d',
      50,
      now(),
      now()
    WHERE NOT EXISTS (SELECT 1 FROM platform.mtr_settings)
    """)
  end

  defp reconcile_retention_policies do
    execute("""
    DO $$
    DECLARE
      table_name text;
      table_ident text;
      retention_days integer;
      ts_schema text;
    BEGIN
      SELECT COALESCE(
        (
          SELECT mtr_retention_days
          FROM platform.mtr_settings
          ORDER BY inserted_at ASC
          LIMIT 1
        ),
        #{@default_retention_days}
      )
      INTO retention_days;

      retention_days := GREATEST(1, LEAST(retention_days, 395));

      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL THEN
        RAISE NOTICE 'Skipping MTR retention reconciliation: TimescaleDB is unavailable';
        RETURN;
      END IF;

      FOREACH table_name IN ARRAY ARRAY['mtr_traces', 'mtr_hops']
      LOOP
        table_ident := format('%I.%I', 'platform', table_name);

        IF NOT EXISTS (
          SELECT 1
          FROM timescaledb_information.hypertables
          WHERE hypertable_schema = 'platform'
            AND hypertable_name = table_name
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            table_ident,
            'time'
          );
        END IF;

        IF EXISTS (
          SELECT 1
          FROM timescaledb_information.hypertables
          WHERE hypertable_schema = 'platform'
            AND hypertable_name = table_name
        ) THEN
          EXECUTE format(
            'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
            ts_schema,
            table_ident
          );

          EXECUTE format(
            'SELECT %I.add_retention_policy(%L::regclass, %L::interval, if_not_exists => true)',
            ts_schema,
            table_ident,
            format('%s days', retention_days)
          );
        ELSE
          RAISE EXCEPTION 'Could not create MTR hypertable for %', table_ident;
        END IF;
      END LOOP;
    END;
    $$;
    """)
  end

  defp configured_retention_days do
    "MTR_RETENTION_DAYS"
    |> System.get_env()
    |> parse_days(@default_retention_days)
    |> max(1)
    |> min(395)
  end

  defp parse_days(nil, default), do: default
  defp parse_days("", default), do: default

  defp parse_days(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {days, ""} -> days
      _ -> default
    end
  end
end
