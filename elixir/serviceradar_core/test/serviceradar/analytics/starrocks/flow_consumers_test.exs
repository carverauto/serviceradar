defmodule ServiceRadar.Analytics.StarRocks.FlowConsumersTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.FlowAttribution.Correlation
  alias ServiceRadar.Observability.NetflowExporterCacheRefreshWorker
  alias ServiceRadar.Observability.ThreatIntelRetrohuntWorker

  @moduletag :db_free

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    on_exit(fn ->
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end)

    %{prev: prev}
  end

  test "exporter cache discovers sampler addresses from StarRocks when flows are cut over",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    query = fn sql ->
      assert sql =~ "sampler_address"
      assert sql =~ "serviceradar.ocsf_network_activity"
      refute sql =~ "platform.ocsf_network_activity"
      send(self(), {:exporter_sql, sql})
      {:ok, %{rows: [["192.0.2.10"], ["198.51.100.20"]]}}
    end

    assert ["192.0.2.10", "198.51.100.20"] ==
             NetflowExporterCacheRefreshWorker.discover_sampler_addresses(1_800, 50, query: query)

    assert_received {:exporter_sql, _sql}
  end

  test "threat retrohunt reads observed flows from StarRocks when flows are cut over",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    assert ThreatIntelRetrohuntWorker.flow_history_backend() == :starrocks

    start_at = ~U[1999-06-15 12:00:00Z]
    end_at = ~U[1999-06-15 13:00:00Z]

    query = fn sql ->
      assert sql =~ "serviceradar.ocsf_network_activity"
      refute sql =~ "platform.ocsf_network_activity"
      send(self(), {:threat_sql, sql})

      {:ok,
       %{
         columns: ["src_endpoint_ip", "dst_endpoint_ip", "bytes_total", "packets_total", "time"],
         rows: [["192.0.2.10", "198.51.100.20", 1200, 10, "1999-06-15 12:00:00"]]
       }}
    end

    assert {:ok, [row]} =
             ThreatIntelRetrohuntWorker.observed_flow_aggregates(start_at, end_at, query: query)

    assert row["src_endpoint_ip"] == "192.0.2.10"
    assert_received {:threat_sql, _sql}
  end

  test "attribution correlation reads recent flows from StarRocks when flows are cut over",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    assert Correlation.flow_history_backend() == :starrocks

    query = fn sql ->
      assert sql =~ "serviceradar.ocsf_network_activity"
      refute sql =~ "platform.ocsf_network_activity"
      refute sql =~ "ctid"
      send(self(), {:attr_sql, sql})

      {:ok,
       %{
         columns: ["id", "time", "src_endpoint_ip", "dst_endpoint_ip"],
         rows: [["flow-alpha-0001", "1999-06-15 12:00:00", "192.0.2.10", "198.51.100.20"]]
       }}
    end

    assert {:ok, [row]} = Correlation.recent_unattributed_flows(query: query)
    assert row["id"] == "flow-alpha-0001"
    assert_received {:attr_sql, _sql}
  end
end
