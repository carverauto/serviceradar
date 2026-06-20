defmodule ServiceRadarWebNGWeb.DeviceLive.SysmonMetricsTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNGWeb.Dashboard.Plugins.Timeseries, as: TimeseriesPlugin
  alias ServiceRadarWebNGWeb.DeviceLive.SysmonMetrics

  @moduletag :db_free

  defmodule RecordingSRQLStub do
    @moduledoc false

    @behaviour ServiceRadarWebNG.SRQLBehaviour

    def query(query) when is_binary(query), do: query(query, %{})
    def query(_query), do: {:error, :invalid_query}

    @impl true
    def query_request(%{"query" => query}) when is_binary(query), do: query(query, %{})
    def query_request(_payload), do: {:error, :invalid_request}

    @impl true
    def query(query, opts) when is_binary(query) do
      responder = Application.fetch_env!(:serviceradar_web_ng, :sysmon_metrics_test_responder)
      responder.(query, opts)
    end
  end

  test "CPU section uses max aggregation split by core" do
    previous_responder = Application.get_env(:serviceradar_web_ng, :sysmon_metrics_test_responder)
    now = DateTime.truncate(DateTime.utc_now(), :second)
    older = DateTime.add(now, -300, :second)

    Application.put_env(:serviceradar_web_ng, :sysmon_metrics_test_responder, fn query, _opts ->
      cond do
        String.contains?(query, ~s|metric_type:"sysmon.cpu"|) ->
          assert query =~ "bucket:5m"
          assert query =~ "agg:max"
          assert query =~ "series:core_id"
          assert query =~ ~s|device_id:"sysmon-core-test"|
          refute query =~ "limit:"

          {:ok,
           %{
             "results" =>
               [
                 %{
                   "timestamp" => DateTime.to_iso8601(now),
                   "value" => 42.4,
                   "core_id" => 0
                 },
                 %{
                   "timestamp" => DateTime.to_iso8601(now),
                   "value" => 91.2,
                   "core_id" => 1
                 },
                 %{
                   "timestamp" => DateTime.to_iso8601(older),
                   "value" => 99.9,
                   "core_id" => 0
                 }
               ] ++
                 Enum.map(2..7, fn core_id ->
                   %{
                     "timestamp" => DateTime.to_iso8601(now),
                     "value" => 10.0 + core_id,
                     "core_id" => core_id
                   }
                 end),
             "pagination" => %{}
           }}

        String.contains?(query, "in:timeseries_metrics") ->
          {:ok, %{"results" => [], "pagination" => %{}}}

        true ->
          {:ok, %{"results" => [], "pagination" => %{}}}
      end
    end)

    on_exit(fn ->
      restore_env(:sysmon_metrics_test_responder, previous_responder)
    end)

    [cpu | _] =
      SysmonMetrics.load_metric_sections(
        RecordingSRQLStub,
        [~s|device_id:"sysmon-core-test"|],
        :scope
      )

    assert cpu.key == "cpu"
    assert cpu.subtitle == "last 24h · 5m buckets · top 6 of 8 cores by max"
    assert cpu.query =~ "agg:max"
    assert cpu.query =~ "series:core_id"
    refute cpu.query =~ "limit:"
    assert cpu.header_value == 91.2
    assert cpu.header_stats == %{min: 12.0, max: 99.9, avg: 35.611111111111114}

    timeseries_panel = Enum.find(cpu.panels, &(&1.plugin == TimeseriesPlugin))
    displayed_cores = MapSet.new(timeseries_panel.assigns.series_points, &elem(&1, 0))
    assert displayed_cores == MapSet.new(~w(0 1 4 5 6 7))
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
