defmodule ServiceRadar.Analytics.StarRocks.MetricConsumersTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.MetricConsumers
  alias ServiceRadar.Observability.AnomalyIngestSilenceWorker

  @moduletag :db_free

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    on_exit(fn ->
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end)

    %{prev: prev}
  end

  test "metrics_alive queries StarRocks timeseries_metrics when metrics are cut over",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:metrics])
    )

    query = fn sql ->
      assert sql =~ "serviceradar.timeseries_metrics"
      refute sql =~ "platform.timeseries_metrics"
      send(self(), {:alive_sql, sql})
      {:ok, %{rows: [[1]], num_rows: 1}}
    end

    assert {:ok, true} =
             MetricConsumers.metrics_alive?(~U[1999-06-15 12:00:00Z], query: query)

    assert_received {:alive_sql, _sql}
  end

  test "snmp_present and directional rows use StarRocks not platform.timeseries_metrics",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:metrics])
    )

    query = fn sql ->
      assert sql =~ "serviceradar.timeseries_metrics"
      refute sql =~ "platform.timeseries_metrics"
      send(self(), {:metric_sql, sql})

      cond do
        sql =~ "metric_type = 'snmp'" ->
          {:ok, %{rows: [[1]], num_rows: 1}}

        sql =~ "MAX(value)" ->
          {:ok, %{rows: [["sr:host-alpha", 1, "ifHCInOctets", "1999-06-15 12:00:00", 1200]]}}

        true ->
          {:ok, %{rows: [["sr:host-alpha", 1, "ifHCInOctets", 1200]]}}
      end
    end

    assert {:ok, true} = MetricConsumers.snmp_present?("sr:host-alpha", query: query)

    assert [{"sr:host-alpha", nil, 1, "ifHCInOctets", 1200}] ==
             MetricConsumers.directional_rows(
               ["sr:host-alpha"],
               [1],
               ["ifHCInOctets"],
               ~U[1999-06-15 12:00:00Z],
               query: query
             )

    assert {:ok, [["sr:host-alpha", 1, "ifHCInOctets", "1999-06-15 12:00:00", 1200]]} ==
             MetricConsumers.sparkline_rows(
               [{"sr:host-alpha", 1}],
               ~U[1999-06-15 12:00:00Z],
               query: query
             )

    assert_received {:metric_sql, _}
  end

  test "anomaly ingest silence uses StarRocks for the metrics-alive probe", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:metrics])
    )

    query = fn sql ->
      assert sql =~ "serviceradar.timeseries_metrics"
      refute sql =~ "platform.timeseries_metrics"
      send(self(), {:silence_sql, sql})
      {:ok, %{rows: [], num_rows: 0}}
    end

    assert :ok =
             AnomalyIngestSilenceWorker.run(
               query: query,
               now: ~U[1999-06-15 12:00:00Z],
               repo: :unused,
               health_recorder: fn _, _, _ ->
                 flunk("should not record while metrics are silent")
               end
             )

    assert_received {:silence_sql, _sql}
  end
end
