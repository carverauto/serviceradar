defmodule ServiceRadar.Analytics.StarRocks.FlowConsumersTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.FlowAttribution.Correlation
  alias ServiceRadar.Observability.IpEnrichmentRefreshWorker
  alias ServiceRadar.Observability.NetflowExporterCacheRefreshWorker
  alias ServiceRadar.Observability.NetflowSecurityRefreshWorker
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

    assert {:ok, ["192.0.2.10", "198.51.100.20"]} ==
             NetflowExporterCacheRefreshWorker.discover_sampler_addresses(1_800, 50, query: query)

    assert_received {:exporter_sql, _sql}
  end

  # Flows are warehouse-only, so discovery reports the routing error rather
  # than an empty list that reads as "this deployment exports no flows".
  test "exporter cache discovery surfaces the routing error until flows are cut over" do
    query = fn sql -> flunk("discovery must not query before cutover: #{sql}") end

    assert {:error, :starrocks_required} ==
             NetflowExporterCacheRefreshWorker.discover_sampler_addresses(1_800, 50, query: query)
  end

  test "attribution correlation reports itself inapplicable until flows are cut over" do
    assert Correlation.correlate() == {:ok, :not_applicable}
  end

  # Every helper in these two workers reads an empty flow result as "no
  # traffic", so a routing refusal that degrades to [] is indistinguishable
  # from an idle network and stays that way forever. They refuse the pass
  # instead.
  test "flow refresh workers refuse to run until flows are cut over" do
    assert {:error, :starrocks_required} =
             NetflowSecurityRefreshWorker.perform(%Oban.Job{args: %{}})

    assert {:error, :starrocks_required} =
             IpEnrichmentRefreshWorker.perform(%Oban.Job{args: %{}})
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
         columns: ["observed_ip", "direction", "bytes_total", "packets_total", "first_seen_at"],
         rows: [["192.0.2.10", "source", 1200, 10, "1999-06-15 12:00:00"]]
       }}
    end

    assert {:ok, [row]} =
             ThreatIntelRetrohuntWorker.observed_flow_aggregates(start_at, end_at, query: query)

    assert row["observed_ip"] == "192.0.2.10"
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

  test "warehouse correlation publishes resolved flow IDs and assigned versions" do
    query = fn _ ->
      {:ok,
       %{
         columns: ["id", "time"],
         rows: [
           ["flow-alpha-0001", ~N[1999-06-15 12:00:00]],
           ["flow-beta-0002", ~N[1999-06-15 12:00:01]]
         ]
       }}
    end

    repo_query = fn _sql, [flows] ->
      assert flows == [
               %{"id" => "flow-alpha-0001", "time" => ~N[1999-06-15 12:00:00]},
               %{"id" => "flow-beta-0002", "time" => ~N[1999-06-15 12:00:01]}
             ]

      {:ok,
       %{
         columns: ["id", "pid", "attribution_version"],
         rows: [["flow-alpha-0001", 42, 101], ["flow-beta-0002", 43, 102]]
       }}
    end

    assert {:ok, 2} =
             Correlation.correlate_starrocks(
               query: query,
               repo_query: repo_query,
               publish: fn %{payload: payload} ->
                 send(self(), {:update, payload})
                 :ok
               end
             )

    # `time` completes the warehouse primary key and must be the value StarRocks
    # returned, not one re-derived by the CNPG matching query.
    assert_received {:update,
                     %{
                       "id" => "flow-alpha-0001",
                       "time" => ~N[1999-06-15 12:00:00],
                       "pid" => 42,
                       "attribution_version" => 101
                     }}

    assert_received {:update,
                     %{
                       "id" => "flow-beta-0002",
                       "time" => ~N[1999-06-15 12:00:01],
                       "pid" => 43,
                       "attribution_version" => 102
                     }}

    assert {:error, :timeout} =
             Correlation.correlate_starrocks(
               query: query,
               repo_query: repo_query,
               publish: fn _ -> {:error, :timeout} end
             )
  end

  test "warehouse correlation propagates matching failures and skips empty batches" do
    assert {:ok, 0} =
             Correlation.correlate_starrocks(
               query: fn _ -> {:ok, %{columns: ["id"], rows: []}} end,
               repo_query: fn _, _ -> flunk("empty batch matched") end
             )

    assert {:error, :unavailable} =
             Correlation.correlate_starrocks(
               query: fn _ ->
                 {:ok,
                  %{
                    columns: ["id", "time"],
                    rows: [["flow-alpha-0001", ~N[1999-06-15 12:00:00]]]
                  }}
               end,
               repo_query: fn _, _ -> {:error, :unavailable} end,
               publish: fn _ -> flunk("failed matches published") end
             )
  end

  test "warehouse observations are aggregated once per run and reused by every batch",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    state = %{
      window_start: ~U[1999-06-15 12:00:00Z],
      window_end: ~U[1999-06-15 13:00:00Z],
      source: "synthetic",
      cursor: nil,
      run_id: "00000000-0000-0000-0000-000000000001"
    }

    aggregations = :counters.new(1, [])

    query = fn _ ->
      :counters.add(aggregations, 1, 1)
      {:ok, %{columns: ["observed_ip", "direction"], rows: [["192.0.2.10", "source"]]}}
    end

    repo_query = fn _sql, params ->
      assert params == [
               state.window_start,
               state.window_end,
               "synthetic",
               nil,
               1,
               state.run_id,
               [%{"observed_ip" => "192.0.2.10", "direction" => "source"}]
             ]

      {:ok, %Postgrex.Result{rows: [[1, 1, "00000000-0000-0000-0000-000000000002", true]]}}
    end

    assert {:ok, observations} =
             ThreatIntelRetrohuntWorker.observations_for_run(state, query: query)

    for _batch <- 1..3 do
      assert {:ok, %{findings_count: 1, indicators_evaluated: 1, complete?: false}} =
               ThreatIntelRetrohuntWorker.run_netflow_match_batch(state, 1, observations,
                 repo_query: repo_query
               )
    end

    assert :counters.get(aggregations, 1) == 1

    assert {:error, %{reason: :unavailable}} =
             ThreatIntelRetrohuntWorker.run_netflow_match_batch(state, 1, observations,
               repo_query: fn _, _ -> {:error, :unavailable} end
             )

    assert {:error, %{run_id: "00000000-0000-0000-0000-000000000001", reason: :unavailable}} =
             ThreatIntelRetrohuntWorker.observations_for_run(state,
               query: fn _ -> {:error, :unavailable} end
             )
  end
end
