defmodule ServiceRadar.Ingestion.RuntimeMetricsCadenceTest do
  @moduledoc """
  The publish cadence of ingestion lane metrics. Each frame becomes one
  `timeseries_metrics` row per lane metric per core node, so the default
  cadence sets that table's volume.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Ingestion.RuntimeMetrics

  @moduletag :db_free

  # The release loads serviceradar_core_elx's runtime config, not this app's.
  @runtime_config Path.expand("../../../../serviceradar_core_elx/config/runtime.exs", __DIR__)
  @external_resource @runtime_config

  @base_env %{
    "CLOAK_KEY" => Base.encode64(:binary.copy(<<7>>, 32)),
    "DATABASE_URL" => "ecto://user:pass@localhost/ingestion_metrics_config_test",
    "SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED" => "false"
  }

  setup do
    previous = Application.get_env(:serviceradar_core, RuntimeMetrics)
    on_exit(fn -> restore_app_env(previous) end)
    :ok
  end

  test "publishes on the configured cadence when started without an interval" do
    Application.put_env(:serviceradar_core, RuntimeMetrics, interval_ms: 20)
    start_metrics!()

    RuntimeMetrics.record(:sweep, :state, %{pending_count: 1})

    assert_receive {:metric_publish, "metrics.ingestion_lanes"}, 1_000
  end

  test "defaults to a cadence far slower than once a second" do
    Application.delete_env(:serviceradar_core, RuntimeMetrics)
    start_metrics!()

    RuntimeMetrics.record(:sweep, :state, %{pending_count: 1})

    # The former 1-second default would publish inside this window.
    refute_receive {:metric_publish, _subject}, 1_500
  end

  test "the deployed core reads the cadence from the environment" do
    assert runtime_interval("15000") == 15_000
    assert runtime_interval(nil) == 30_000
    assert runtime_interval("10") == 1_000
  end

  defp start_metrics! do
    parent = self()

    request = fn subject, _body, _opts ->
      send(parent, {:metric_publish, subject})
      {:ok, %{body: Jason.encode!(%{stream: "METRICS", seq: 1})}}
    end

    start_supervised!({RuntimeMetrics, publish_opts: [request: request]})
  end

  defp runtime_interval(value) do
    environment =
      Map.put(@base_env, "SERVICERADAR_INGESTION_METRICS_INTERVAL_MS", value)

    previous = Map.new(environment, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(environment, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)

    try do
      Config.Reader.read!(@runtime_config, env: :prod)[:serviceradar_core][RuntimeMetrics][
        :interval_ms
      ]
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp restore_app_env(nil), do: Application.delete_env(:serviceradar_core, RuntimeMetrics)
  defp restore_app_env(value), do: Application.put_env(:serviceradar_core, RuntimeMetrics, value)
end
