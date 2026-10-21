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
