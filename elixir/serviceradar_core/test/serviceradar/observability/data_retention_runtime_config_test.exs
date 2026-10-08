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
        "SERVICERADAR_TIMESERIES_METRICS_COMPRESS_AFTER_HOURS" => "6"
      })

    assert worker[:hourly_rollup_retention_days] == 14
    assert worker[:timeseries_metrics_retention_days] == 10
    assert worker[:timeseries_metrics_compress_after_hours] == 6
  end

  test "unset retention keeps the shipped windows" do
    worker =
      worker_config(%{
        "SERVICERADAR_HOURLY_ROLLUP_RETENTION_DAYS" => nil,
        "SERVICERADAR_TIMESERIES_METRICS_RETENTION_DAYS" => nil,
        "SERVICERADAR_TIMESERIES_METRICS_COMPRESS_AFTER_HOURS" => nil
      })

    assert worker[:hourly_rollup_retention_days] == 395
    assert worker[:timeseries_metrics_retention_days] == 7
    assert worker[:timeseries_metrics_compress_after_hours] == 24
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
