defmodule ServiceRadar.Observability.DataRetentionRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Observability.DataRetentionWorker

  @moduletag :db_free
  # The release loads serviceradar_core_elx's runtime config, not this app's, and
  # it once dropped timeseries_metrics_retention_days without anything noticing.
  @runtime_config Path.expand("../../../../serviceradar_core_elx/config/runtime.exs", __DIR__)
  @external_resource @runtime_config

  @base_env %{
    "CLOAK_KEY" => Base.encode64(:binary.copy(<<7>>, 32)),
    "DATABASE_URL" => "ecto://user:pass@localhost/retention_config_test",
    "SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED" => "false"
  }

  test "the deployed core passes rollup and timeseries retention to the worker" do
    worker =
      worker_config(%{
        "SERVICERADAR_HOURLY_ROLLUP_RETENTION_DAYS" => "14",
        "SERVICERADAR_TIMESERIES_METRICS_RETENTION_DAYS" => "10",
        "SERVICERADAR_TIMESERIES_METRICS_COMPRESS_AFTER_HOURS" => "6",
        "SERVICERADAR_TIMESERIES_METRICS_CHUNK_INTERVAL_HOURS" => "3"
      })

    assert worker[:hourly_rollup_retention_days] == 14
    assert worker[:timeseries_metrics_retention_days] == 10
    assert worker[:timeseries_metrics_compress_after_hours] == 6
    assert worker[:timeseries_metrics_chunk_interval_hours] == 3
  end

  test "unset retention keeps the shipped windows" do
    worker =
      worker_config(%{
        "SERVICERADAR_HOURLY_ROLLUP_RETENTION_DAYS" => nil,
        "SERVICERADAR_TIMESERIES_METRICS_RETENTION_DAYS" => nil,
        "SERVICERADAR_TIMESERIES_METRICS_COMPRESS_AFTER_HOURS" => nil,
        "SERVICERADAR_TIMESERIES_METRICS_CHUNK_INTERVAL_HOURS" => nil
      })

    assert worker[:hourly_rollup_retention_days] == 395
    assert worker[:timeseries_metrics_retention_days] == 7
    assert worker[:timeseries_metrics_compress_after_hours] == 2
    assert worker[:timeseries_metrics_chunk_interval_hours] == 4
  end

  test "cagg refresh policy specs clamp start_offset strictly below source retention" do
    specs =
      DataRetentionWorker.cagg_refresh_policy_specs(
        otel_traces_retention_days: 1,
        logs_retention_days: 1,
        ocsf_events_retention_days: 1,
        otel_metrics_retention_days: 1,
        timeseries_metrics_retention_days: 1,
        raw_metrics_retention_days: 1
      )

    by_view = Map.new(specs, &{&1.view, &1})

    assert by_view["spans_red_1h"].start_offset == "12 hours"
    assert by_view["traces_stats_5m"].start_offset == "12 hours"
    assert by_view["logs_severity_stats_5m"].start_offset == "3 hours"
    assert by_view["ocsf_events_hourly_stats"].start_offset == "12 hours"

    for spec <- specs do
      assert spec.start_offset_hours < spec.source_retention_days * 24
    end
  end

  test "the deployed core passes per-dataset CNPG retention to the worker" do
    worker =
      worker_config(%{
        "SERVICERADAR_OTEL_METRICS_RETENTION_DAYS" => "11",
        "SERVICERADAR_OTEL_METRIC_POINTS_RETENTION_DAYS" => "12",
        "SERVICERADAR_OCSF_EVENTS_RETENTION_DAYS" => "13",
        "SERVICERADAR_RAW_METRICS_RETENTION_DAYS" => "8",
        "SERVICERADAR_CAPACITY_FORECASTS_RETENTION_DAYS" => "40",
        "SERVICERADAR_CNPG_TELEMETRY_DEFAULT_DAYS" => "9",
        "SERVICERADAR_OTEL_METRICS_CHUNK_INTERVAL_HOURS" => "5",
        "SERVICERADAR_OTEL_METRIC_POINTS_CHUNK_INTERVAL_HOURS" => "4",
        "SERVICERADAR_OCSF_EVENTS_CHUNK_INTERVAL_HOURS" => "3",
        "SERVICERADAR_RAW_METRICS_CHUNK_INTERVAL_HOURS" => "2",
        "SERVICERADAR_CAPACITY_FORECASTS_CHUNK_INTERVAL_HOURS" => "6"
      })

    assert worker[:otel_metrics_retention_days] == 11
    assert worker[:otel_metric_points_retention_days] == 12
    assert worker[:ocsf_events_retention_days] == 13
    assert worker[:raw_metrics_retention_days] == 8
    assert worker[:capacity_forecasts_retention_days] == 40
    assert worker[:cnpg_telemetry_default_days] == 9
    assert worker[:otel_metrics_chunk_interval_hours] == 5
    assert worker[:otel_metric_points_chunk_interval_hours] == 4
    assert worker[:ocsf_events_chunk_interval_hours] == 3
    assert worker[:raw_metrics_chunk_interval_hours] == 2
    assert worker[:capacity_forecasts_chunk_interval_hours] == 6
  end

  test "a blank telemetry ceiling keeps the shipped per-dataset windows" do
    worker =
      worker_config(%{
        "SERVICERADAR_CNPG_TELEMETRY_DEFAULT_DAYS" => "",
        "SERVICERADAR_OTEL_METRICS_RETENTION_DAYS" => nil,
        "SERVICERADAR_OTEL_METRIC_POINTS_RETENTION_DAYS" => nil,
        "SERVICERADAR_OCSF_EVENTS_RETENTION_DAYS" => nil,
        "SERVICERADAR_RAW_METRICS_RETENTION_DAYS" => nil,
        "SERVICERADAR_CAPACITY_FORECASTS_RETENTION_DAYS" => nil
      })

    assert worker[:cnpg_telemetry_default_days] == nil
    assert worker[:otel_metrics_retention_days] == 30
    assert worker[:otel_metric_points_retention_days] == 30
    assert worker[:ocsf_events_retention_days] == 14
    assert worker[:raw_metrics_retention_days] == 7
    assert worker[:capacity_forecasts_retention_days] == 395
  end

  test "the telemetry ceiling caps raw windows and leaves forecasts alone" do
    config = [
      cnpg_telemetry_default_days: 7,
      logs_retention_days: 3,
      capacity_forecasts_retention_days: 40,
      hourly_rollup_retention_days: 395
    ]

    applied = DataRetentionWorker.telemetry_retention_days(config)

    assert applied["logs"] == 3
    assert applied["otel_traces"] == 3
    assert applied["otel_trace_summaries"] == 3
    assert applied["otel_metrics"] == 7
    assert applied["otel_metric_points"] == 7
    assert applied["ocsf_events"] == 7
    assert applied["timeseries_metrics"] == 7
    assert applied["cpu_metrics"] == 7
    refute Map.has_key?(applied, "ocsf_network_activity")
    assert applied["capacity_forecasts"] == 40

    assert DataRetentionWorker.hourly_rollup_retention_days(config) == 7

    assert DataRetentionWorker.hourly_rollup_retention_days(
             cnpg_telemetry_default_days: 1,
             hourly_rollup_retention_days: 395
           ) == 7

    shipped = DataRetentionWorker.telemetry_retention_days([])
    assert shipped["otel_metrics"] == 30
    assert shipped["logs"] == 30
    assert shipped["otel_traces"] == 3
    assert shipped["capacity_forecasts"] == 395
    assert DataRetentionWorker.hourly_rollup_retention_days([]) == 395

    assert DataRetentionWorker.telemetry_retention_days(cnpg_telemetry_default_days: 0)[
             "otel_metrics"
           ] == 30

    specs = DataRetentionWorker.cagg_refresh_policy_specs(cnpg_telemetry_default_days: 1)

    # The endpoint inventory count rollups refresh from the history tables,
    # whose horizon the ceiling deliberately does not cap.
    uncapped = ~w(
      endpoint_inventory_package_counts_hourly
      endpoint_inventory_cpe_counts_hourly
    )

    for spec <- specs do
      if spec.view in uncapped do
        assert spec.source_retention_days == 395
      else
        assert spec.source_retention_days == 1
      end

      assert spec.start_offset_hours < spec.source_retention_days * 24
    end
  end

  test "the deployed core passes migration-table retention to the worker" do
    worker =
      worker_config(%{
        "SERVICERADAR_ADHOC_SCAN_RESULTS_RETENTION_DAYS" => "11",
        "SERVICERADAR_SERVICE_STATUS_RETENTION_DAYS" => "12",
        "SERVICERADAR_ENDPOINT_INVENTORY_HISTORY_RETENTION_DAYS" => "40",
        "SERVICERADAR_SPANS_RED_RETENTION_DAYS" => "13",
        "SERVICERADAR_TRACES_STATS_RETENTION_DAYS" => "21",
        "SERVICERADAR_OTEL_METRICS_HOURLY_STATS_RETENTION_DAYS" => "22"
      })

    assert worker[:adhoc_scan_results_retention_days] == 11
    assert worker[:service_status_retention_days] == 12
    assert worker[:endpoint_inventory_history_retention_days] == 40
    assert worker[:spans_red_retention_days] == 13
    assert worker[:traces_stats_retention_days] == 21
    assert worker[:otel_metrics_hourly_stats_retention_days] == 22
  end

  test "unset migration-table retention keeps the migration windows; traces stats stays unset" do
    worker =
      worker_config(%{
        "SERVICERADAR_ADHOC_SCAN_RESULTS_RETENTION_DAYS" => nil,
        "SERVICERADAR_SERVICE_STATUS_RETENTION_DAYS" => nil,
        "SERVICERADAR_ENDPOINT_INVENTORY_HISTORY_RETENTION_DAYS" => nil,
        "SERVICERADAR_SPANS_RED_RETENTION_DAYS" => nil,
        "SERVICERADAR_TRACES_STATS_RETENTION_DAYS" => nil,
        "SERVICERADAR_OTEL_METRICS_HOURLY_STATS_RETENTION_DAYS" => nil
      })

    assert worker[:adhoc_scan_results_retention_days] == 30
    assert worker[:service_status_retention_days] == 14
    assert worker[:endpoint_inventory_history_retention_days] == 395
    assert worker[:spans_red_retention_days] == 90
    # Nil, not the 14-day default: the worker must tell an explicit
    # tracesStatsDays from an unset one to protect a fence-widened window.
    assert worker[:traces_stats_retention_days] == nil
    assert worker[:otel_metrics_hourly_stats_retention_days] == 90
  end

  defp worker_config(overrides) do
    environment = Map.merge(@base_env, overrides)
    previous = Map.new(environment, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(environment, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Config.Reader.read!(@runtime_config, env: :prod)[:serviceradar_core][DataRetentionWorker]
  end
end
