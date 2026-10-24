defmodule ServiceRadar.Observability.MigrationTableRetentionDbTest do
  @moduledoc """
  `DataRetentionWorker.reconcile_migration_tables/1` against the real
  migration-only hypertables and continuous aggregates. Serial because it
  alters shared tables; the sandbox transaction rolls the DDL back.
  """

  use ServiceRadar.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ServiceRadar.Observability.DataRetentionWorker
  alias ServiceRadar.Repo

  @moduletag :integration

  @hypertables ~w(
    adhoc_scan_results
    service_status
    events
    endpoint_inventory_scan_history
    endpoint_inventory_package_events
    endpoint_inventory_package_count_history
    endpoint_inventory_cpe_count_history
  )

  @caggs ~w(
    spans_red_1h
    traces_stats_5m
    otel_metrics_hourly_stats
    endpoint_inventory_package_counts_hourly
    endpoint_inventory_cpe_counts_hourly
    services_availability_5m
  )

  setup do
    # The worker skips absent objects, so without this every assertion below
    # could pass against a schema that has none of them.
    assert present_hypertables() == Enum.sort(@hypertables)
    assert present_caggs() == Enum.sort(@caggs)
    :ok
  end

  test "applies configured retention to the migration-only hypertables" do
    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(
               adhoc_scan_results_retention_days: 7,
               service_status_retention_days: 7
             )

    assert hypertable_drop_after("adhoc_scan_results") == "7 days"
    assert hypertable_drop_after("service_status") == "7 days"
    assert hypertable_drop_after("events") == "7 days"

    # A second run at the same values leaves the policies in place.
    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(
               adhoc_scan_results_retention_days: 7,
               service_status_retention_days: 7
             )

    assert hypertable_drop_after("adhoc_scan_results") == "7 days"
    assert hypertable_drop_after("service_status") == "7 days"
    assert hypertable_drop_after("events") == "7 days"
  end

  test "applies endpoint inventory history retention and clamps its count rollups first" do
    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(
               endpoint_inventory_history_retention_days: 7
             )

    for table <- ~w(
          endpoint_inventory_scan_history
          endpoint_inventory_package_events
          endpoint_inventory_package_count_history
          endpoint_inventory_cpe_count_history
        ) do
      assert hypertable_drop_after(table) == "7 days", table
    end

    assert interval_under_days?(
             refresh_start_offset("endpoint_inventory_package_counts_hourly"),
             7
           )

    assert interval_under_days?(refresh_start_offset("endpoint_inventory_cpe_counts_hourly"), 7)
  end

  test "defaults preserve the migration retention values" do
    assert :ok = DataRetentionWorker.reconcile_migration_tables([])

    assert hypertable_drop_after("adhoc_scan_results") == "30 days"
    assert hypertable_drop_after("service_status") == "14 days"
    assert hypertable_drop_after("events") == "14 days"
    assert hypertable_drop_after("endpoint_inventory_scan_history") == "395 days"
    assert hypertable_drop_after("endpoint_inventory_package_events") == "395 days"
    assert hypertable_drop_after("endpoint_inventory_package_count_history") == "395 days"
    assert hypertable_drop_after("endpoint_inventory_cpe_count_history") == "395 days"
    assert cagg_drop_after("spans_red_1h") == "90 days"
    assert cagg_drop_after("traces_stats_5m") == "14 days"
    assert cagg_drop_after("otel_metrics_hourly_stats") == "90 days"
  end

  test "the ceiling caps raw datasets but not the endpoint inventory history horizon" do
    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(cnpg_telemetry_default_days: 7)

    assert hypertable_drop_after("adhoc_scan_results") == "7 days"
    assert hypertable_drop_after("endpoint_inventory_scan_history") == "395 days"
    assert hypertable_drop_after("endpoint_inventory_cpe_count_history") == "395 days"
  end

  test "one-day service status retention clamps the availability refresh strictly under it" do
    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(cnpg_telemetry_default_days: 1)

    assert hypertable_drop_after("service_status") == "1 day"
    assert hypertable_drop_after("events") == "1 day"
    assert interval_under_days?(refresh_start_offset("services_availability_5m"), 1)
  end

  test "hourly otel stats retention clamps its own refresh window" do
    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(
               otel_metrics_hourly_stats_retention_days: 7,
               otel_metrics_retention_days: 30
             )

    assert cagg_drop_after("otel_metrics_hourly_stats") == "7 days"
    assert interval_under_days?(refresh_start_offset("otel_metrics_hourly_stats"), 7)
  end

  test "unset traces stats and the ceiling leave a fence-widened window alone" do
    set_cagg_retention("traces_stats_5m", 90)

    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(cnpg_telemetry_default_days: 7)

    assert cagg_drop_after("traces_stats_5m") == "90 days"
  end

  test "explicit traces stats retention narrows a widened window with the cold tier off" do
    set_cagg_retention("traces_stats_5m", 90)

    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(traces_stats_retention_days: 30)

    assert cagg_drop_after("traces_stats_5m") == "30 days"
  end

  test "the ceiling does not cap traces stats on the migration interval" do
    set_cagg_retention("traces_stats_5m", 14)

    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(cnpg_telemetry_default_days: 7)

    assert cagg_drop_after("traces_stats_5m") == "14 days"
  end

  test "an explicit traces stats value is not ceiling-capped on a widened window" do
    set_cagg_retention("traces_stats_5m", 90)

    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(
               traces_stats_retention_days: 30,
               cnpg_telemetry_default_days: 7
             )

    assert cagg_drop_after("traces_stats_5m") == "30 days"

    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(
               traces_stats_retention_days: 30,
               cnpg_telemetry_default_days: 7
             )

    assert cagg_drop_after("traces_stats_5m") == "30 days"
  end

  test "an explicit traces stats value at or below 14 days stays on the next run" do
    for days <- [10, 14] do
      set_cagg_retention("traces_stats_5m", 90)

      assert :ok =
               DataRetentionWorker.reconcile_migration_tables(
                 traces_stats_retention_days: days,
                 cnpg_telemetry_default_days: 7
               )

      assert cagg_drop_after("traces_stats_5m") == "#{days} days"

      assert :ok =
               DataRetentionWorker.reconcile_migration_tables(
                 traces_stats_retention_days: days,
                 cnpg_telemetry_default_days: 7
               )

      assert cagg_drop_after("traces_stats_5m") == "#{days} days"
    end
  end

  test "an explicit traces stats value above the fence target is written" do
    set_cagg_retention("traces_stats_5m", 90)

    assert :ok =
             DataRetentionWorker.reconcile_migration_tables(
               traces_stats_retention_days: 120,
               cnpg_telemetry_default_days: 7
             )

    assert cagg_drop_after("traces_stats_5m") == "120 days"
  end

  defp present_hypertables do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT hypertable_name
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'platform' AND hypertable_name = ANY($1)
        ORDER BY hypertable_name
        """,
        [@hypertables]
      )

    List.flatten(rows)
  end

  defp present_caggs do
    %{rows: rows} =
      SQL.query!(
        Repo,
        """
        SELECT view_name
        FROM timescaledb_information.continuous_aggregates
        WHERE view_schema = 'platform' AND view_name = ANY($1)
        ORDER BY view_name
        """,
        [@caggs]
      )

    List.flatten(rows)
  end

  defp hypertable_drop_after(table) do
    %{rows: [[drop_after]]} =
      SQL.query!(
        Repo,
        """
        SELECT config->>'drop_after'
        FROM timescaledb_information.jobs
        WHERE proc_name = 'policy_retention'
          AND hypertable_schema = 'platform'
          AND hypertable_name = $1
        """,
        [table]
      )

    drop_after
  end

  defp cagg_drop_after(view) do
    %{rows: [[drop_after]]} =
      SQL.query!(
        Repo,
        """
        SELECT j.config->>'drop_after'
        FROM timescaledb_information.continuous_aggregates ca
        JOIN timescaledb_information.jobs j
          ON j.proc_name = 'policy_retention'
         AND j.hypertable_schema IN (ca.materialization_hypertable_schema, ca.view_schema)
         AND j.hypertable_name IN (ca.view_name, ca.materialization_hypertable_name)
        WHERE ca.view_schema = 'platform' AND ca.view_name = $1
        """,
        [view]
      )

    drop_after
  end

  defp refresh_start_offset(view) do
    %{rows: [[start_offset]]} =
      SQL.query!(
        Repo,
        """
        SELECT (j.config->>'start_offset')::interval
        FROM timescaledb_information.continuous_aggregates ca
        JOIN timescaledb_information.jobs j
          ON j.proc_name = 'policy_refresh_continuous_aggregate'
         AND j.hypertable_schema IN (ca.materialization_hypertable_schema, ca.view_schema)
         AND j.hypertable_name IN (ca.materialization_hypertable_name, ca.view_name)
        WHERE ca.view_schema = 'platform' AND ca.view_name = $1
        """,
        [view]
      )

    start_offset
  end

  # Simulate the cold-tier fence having widened the window in an earlier run.
  defp set_cagg_retention(view, days) do
    SQL.query!(
      Repo,
      """
      DO $$
      DECLARE
        ts_schema text;
      BEGIN
        SELECT n.nspname INTO ts_schema
        FROM pg_extension e
        JOIN pg_namespace n ON n.oid = e.extnamespace
        WHERE e.extname = 'timescaledb';

        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema, 'platform.#{view}'
        );
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, make_interval(days => #{days}), if_not_exists => true)',
          ts_schema, 'platform.#{view}'
        );
      END;
      $$;
      """,
      []
    )
  end

  defp interval_under_days?(%Postgrex.Interval{} = interval, days) do
    total_seconds =
      interval.months * 30 * 86_400 + interval.days * 86_400 + interval.secs +
        interval.microsecs / 1_000_000

    total_seconds < days * 86_400
  end
end
