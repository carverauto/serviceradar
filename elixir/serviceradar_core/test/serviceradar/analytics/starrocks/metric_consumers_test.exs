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
          {:ok, %{rows: [["sr:host-alpha", "192.0.2.10", 1, "ifHCInOctets", 1200]]}}
      end
    end

    assert {:ok, true} = MetricConsumers.snmp_present?("sr:host-alpha", query: query)

    assert [{"sr:host-alpha", "192.0.2.10", 1, "ifHCInOctets", 1200}] ==
             MetricConsumers.directional_rows(
               ["sr:host-alpha"],
               ["192.0.2.10"],
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

  test "directional rows carry the same scope and latest-sample semantics as CNPG" do
    parent = self()

    query = fn sql ->
      send(parent, {:directional_sql, sql})

      {:ok,
       %{
         rows: [
           ["sr:host-alpha", nil, 1, "ifHCInOctets::ifIndex", 4_000],
           [nil, "192.0.2.10", 2, "ifHCOutOctets", 9_000]
         ]
       }}
    end

    rows =
      MetricConsumers.directional_rows(
        ["sr:host-alpha"],
        ["192.0.2.10"],
        [1, 2],
        ["ifHCInOctets", "ifHCOutOctets"],
        ~U[1999-06-15 12:00:00Z],
        query: query
      )

    # A device reachable only by target IP still resolves, because the IP now
    # reaches both the scope and the tuple the topology reducer keys on.
    assert rows == [
             {"sr:host-alpha", nil, 1, "ifHCInOctets::ifIndex", 4_000},
             {nil, "192.0.2.10", 2, "ifHCOutOctets", 9_000}
           ]

    assert_received {:directional_sql, sql}

    # The statement the warehouse runs must reduce each
    # (device, target IP, if_index, metric) to its newest sample. Without this
    # the topology reducer's max/2 fold renders the window's peak utilization
    # as the link's current value.
    assert sql =~
             "ROW_NUMBER() OVER (PARTITION BY device_id, target_device_ip, if_index, " <>
               "metric_name ORDER BY `timestamp` DESC)"

    assert sql =~ "sample_rank = 1"

    # Suffixed series such as ifHCInOctets::ifIndex must still match.
    assert sql =~ "split_part(metric_name, '::', 1) IN ('ifHCInOctets','ifHCOutOctets')"

    assert sql =~ "(device_id IN ('sr:host-alpha') OR target_device_ip IN ('192.0.2.10'))"
  end

  test "directional rows scope on device id alone when no target IPs are known" do
    parent = self()

    query = fn sql ->
      send(parent, {:directional_sql, sql})
      {:ok, %{rows: []}}
    end

    assert [] ==
             MetricConsumers.directional_rows(
               ["sr:host-alpha"],
               [],
               [1],
               ["ifHCInOctets"],
               ~U[1999-06-15 12:00:00Z],
               query: query
             )

    assert_received {:directional_sql, sql}
    assert sql =~ "device_id IN ('sr:host-alpha')"
    refute sql =~ "target_device_ip IN ()"
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
