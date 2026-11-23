defmodule ServiceRadarWebNG.SRQLStarRocksModeTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNG.SRQL
  alias ServiceRadarWebNGWeb.DashboardLive.Data
  alias ServiceRadarWebNGWeb.DashboardLive.Window

  @moduletag :db_free

  @flows_query "in:flows time:last_1h limit:1"
  @scope %{permissions: MapSet.new(["observability.netflow.view"])}

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])

    on_exit(fn ->
      Application.put_env(:serviceradar_core, StarRocks, prev)
    end)

    %{prev: prev}
  end

  # NetFlow has no CNPG serving path: an installation that has not cut flows
  # over is told so, instead of being handed CNPG rows that answer the same
  # question over a different retention window.
  test "authorized flow queries refuse to serve while cutover_datasets is empty" do
    result =
      try do
        SRQL.query(@flows_query, %{scope: @scope})
      rescue
        exception -> {:rescued, exception}
      end

    assert result == {:error, :starrocks_required}
  end

  test "an unauthorized flow query is still forbidden before routing refuses" do
    assert {:error, :forbidden} =
             SRQL.query(@flows_query, %{scope: %{permissions: MapSet.new()}})
  end

  test "datasets that are not cut over and are not flows still read CNPG" do
    scope = %{permissions: MapSet.new(["observability.logs.view"])}

    result =
      try do
        SRQL.query("in:logs time:last_1h limit:1", %{scope: scope})
      rescue
        exception -> {:rescued, exception}
      end

    assert match?({:rescued, %RuntimeError{message: "could not lookup Ecto repo" <> _}}, result)
  end

  test "authorized flow queries execute compiled StarRocks SQL when cutover_datasets lists flows",
       %{prev: prev} do
    parent = self()

    mysql = fn sql ->
      # A row listing can never read an hourly view, so the rollup gate must
      # not spend a Frontend round trip probing one.
      refute sql =~ "MAX(`bucket`)"
      send(parent, {:starrocks_query, sql})
      {:ok, postgrex_result(["id", "bytes_in"], [["flow-alpha-0001", 1200]])}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:mysql, mysql)
    )

    for query <- [
          @flows_query,
          "IN:flows time:last_1h limit:1",
          "time:last_1h in:flows limit:1",
          "in:logs time:last_1h IN:flows limit:1"
        ] do
      assert {:ok, %{"results" => [row], "error" => nil}} =
               SRQL.query(query, %{scope: @scope})

      assert row["id"] == "flow-alpha-0001"
      assert row["bytes_in"] == 1200
      assert_received {:starrocks_query, body}
      assert body =~ "ocsf_network_activity"
      refute body =~ "time_bucket"
    end
  end

  test "authorized last_1h map stats select StarRocks when flows are in cutover_datasets",
       %{prev: prev} do
    parent = self()

    mysql = fn sql ->
      send(parent, {:starrocks_query, sql})

      {:ok,
       postgrex_result(
         ["bytes_total", "src_endpoint_ip", "dst_endpoint_ip"],
         [[1200, "192.0.2.10", "198.51.100.20"]]
       )}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:mysql, mysql)
    )

    window = Window.resolve("last_1h", "netflow")
    query = ServiceRadarWebNGWeb.DashboardLive.Data.NetflowTraffic.srql_query(window)

    assert {:ok, %{"results" => [row], "error" => nil}} =
             SRQL.query(query, %{scope: @scope})

    assert row["bytes_total"] == 1200
    assert_received {:starrocks_query, body}
    assert body =~ "ocsf_network_activity"
    assert body =~ "GROUP BY src_endpoint_ip, dst_endpoint_ip, `partition`"
    refute body =~ "time_bucket"
  end

  # Backend routing is a server-side decision. A caller-supplied mode used to
  # short-circuit it, which both read a cut-over dataset from CNPG and skipped
  # the rollup-freshness gate.
  test "a request-supplied mode cannot reach StarRocks for a dataset that is not cut over",
       %{prev: prev} do
    mysql = fn sql -> flunk("request mode must not route to StarRocks: #{sql}") end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :mysql, mysql)
    )

    assert SRQL.query(@flows_query, %{scope: @scope, mode: "starrocks"}) ==
             {:error, :starrocks_required}
  end

  test "a request-supplied mode cannot pull a cut-over dataset back to CNPG", %{prev: prev} do
    parent = self()

    mysql = fn sql ->
      send(parent, {:starrocks_query, sql})
      {:ok, postgrex_result(["id", "bytes_in"], [["flow-alpha-0001", 1200]])}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:mysql, mysql)
    )

    assert {:ok, %{"results" => [row]}} =
             SRQL.query(@flows_query, %{scope: @scope, mode: "cnpg"})

    assert row["id"] == "flow-alpha-0001"
    assert_received {:starrocks_query, body}
    assert body =~ "FROM serviceradar.ocsf_network_activity"
  end

  test "authorized timeseries queries execute StarRocks SQL when the warehouse is enabled",
       %{prev: prev} do
    parent = self()
    scope = %{permissions: MapSet.new(["observability.metrics.view"])}

    mysql = fn sql ->
      send(parent, {:starrocks_query, sql})
      {:ok, postgrex_result(["device_id", "value"], [["sr:host-alpha", 42.0]])}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:cutover_datasets, [])
      |> Keyword.put(:mysql, mysql)
    )

    assert {:ok, %{"results" => [row], "error" => nil}} =
             SRQL.query("in:timeseries_metrics time:last_1h limit:1", %{scope: scope})

    assert row["device_id"] == "sr:host-alpha"
    assert_received {:starrocks_query, body}
    assert body =~ "timeseries_metrics"
    refute body =~ "platform.timeseries_metrics"
  end

  test "netperf aliases route through StarRocks when enabled and CNPG when disabled",
       %{prev: prev} do
    parent = self()
    scope = %{permissions: MapSet.new(["observability.metrics.view"])}

    mysql = fn sql ->
      send(parent, {:starrocks_query, sql})
      {:ok, postgrex_result(["metric_name", "value"], [["rperf.bits_per_second", 50_000_000.0]])}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:enabled, true)
      |> Keyword.put(:cutover_datasets, [])
      |> Keyword.put(:mysql, mysql)
    )

    for alias_name <- ~w(netperf_metrics netperf) do
      assert {:ok, %{"results" => [row], "error" => nil}} =
               SRQL.query("in:#{alias_name} time:last_1h limit:1", %{scope: scope})

      assert row["metric_name"] == "rperf.bits_per_second"
      assert_received {:starrocks_query, body}
      assert body =~ "timeseries_metrics"
      assert body =~ "metric_type = 'rperf'"
    end

    # When StarRocks is disabled, the same queries fall back to CNPG (Ecto repo).
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :enabled, false)
    )

    for alias_name <- ~w(netperf_metrics netperf) do
      result =
        try do
          SRQL.query("in:#{alias_name} time:last_1h limit:1", %{scope: scope})
        rescue
          exception -> {:rescued, exception}
        end

      assert match?({:rescued, %RuntimeError{message: "could not lookup Ecto repo" <> _}}, result)
    end
  end

  test "enrichment queries error when the JDBC catalog is disabled", %{prev: prev} do
    mysql = fn _sql ->
      flunk("catalog-disabled enrichment must not call StarRocks")
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:mysql, mysql)
    )

    # `hostname` is what pulls in the CNPG catalog join; the catalog flag gates
    # it before any SQL reaches the Frontend.
    assert {:error, {:starrocks_catalog_disabled, "cnpg_platform"}} =
             SRQL.query("in:flows time:last_1h hostname:host01 limit:1", %{scope: @scope})
  end

  test "attributed flows read persisted attribution, never a catalog join", %{prev: prev} do
    parent = self()

    mysql = fn sql ->
      send(parent, {:starrocks_query, sql})
      {:ok, postgrex_result(["id", "comm"], [["flow-alpha-0001", "sshd"]])}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:mysql, mysql)
    )

    assert {:ok, %{"results" => [row], "error" => nil}} =
             SRQL.query("in:attributed_flows time:last_1h limit:1", %{scope: @scope})

    assert row["id"] == "flow-alpha-0001"
    assert_received {:starrocks_query, body}

    # pid/comm come off the observation row, so this page compiles and runs with
    # the catalog switched off -- it must not reach cnpg_platform at all.
    assert body =~ "serviceradar.ocsf_network_activity"
    assert body =~ "pid"
    assert body =~ "comm"
    refute body =~ "cnpg_platform"
    refute body =~ "flow_process_attribution_current"
  end

  test "enrichment queries compile the CNPG catalog join when the catalog is enabled",
       %{prev: prev} do
    parent = self()

    mysql = fn sql ->
      send(parent, {:starrocks_query, sql})
      {:ok, postgrex_result(["id", "hostname"], [["flow-alpha-0001", "host01"]])}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:catalog_enabled, true)
      |> Keyword.put(:mysql, mysql)
    )

    assert {:ok, %{"results" => [row], "error" => nil}} =
             SRQL.query("in:flows time:last_1h hostname:host01 limit:1", %{scope: @scope})

    assert row["id"] == "flow-alpha-0001"
    assert_received {:starrocks_query, body}
    assert body =~ "cnpg_platform.platform.ocsf_devices"
    refute body =~ "flow_process_attribution_current"
    refute body =~ "network_credential_secrets"
  end

  test "authorized log and event queries execute StarRocks SQL when those datasets are cut over",
       %{prev: prev} do
    parent = self()
    logs_scope = %{permissions: MapSet.new(["observability.logs.view"])}
    events_scope = %{permissions: MapSet.new(["observability.events.view"])}

    mysql = fn sql ->
      send(parent, {:starrocks_query, sql})
      {:ok, postgrex_result(["id", "severity"], [["row-alpha-0001", "low"]])}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:logs, :events])
      |> Keyword.put(:mysql, mysql)
    )

    assert {:ok, %{"results" => [log_row], "error" => nil}} =
             SRQL.query("in:logs time:last_1h limit:1", %{scope: logs_scope})

    assert log_row["id"] == "row-alpha-0001"
    assert log_row["severity"] == "low"
    assert_received {:starrocks_query, logs_body}
    assert logs_body =~ "serviceradar.logs"
    refute logs_body =~ "platform.logs"

    assert {:ok, %{"results" => [event_row], "error" => nil}} =
             SRQL.query("in:events time:last_1h limit:1", %{scope: events_scope})

    assert event_row["id"] == "row-alpha-0001"
    assert event_row["severity"] == "low"
    assert_received {:starrocks_query, events_body}
    assert events_body =~ "serviceradar.events"
    refute events_body =~ "platform.ocsf_events"

    assert {:error, :forbidden} =
             SRQL.query("in:logs time:last_1h limit:1", %{scope: %{permissions: MapSet.new()}})
  end

  # CNPG returns an event's jsonb documents as maps; the warehouse stores them
  # as JSON text. The event pages index into them, so the row has to arrive in
  # CNPG's shape whichever backend answered.
  test "a cut-over event row carries its documents as maps, and a log row is left alone",
       %{prev: prev} do
    events_scope = %{permissions: MapSet.new(["observability.events.view"])}
    logs_scope = %{permissions: MapSet.new(["observability.logs.view"])}
    columns = ["id", "metadata", "unmapped", "device", "observables"]

    documents = [
      "row-alpha-0002",
      ~s({"security_signal":{"finding_uid":"finding-0001"}}),
      "{}",
      nil,
      "not json"
    ]

    mysql = fn _sql -> {:ok, postgrex_result(columns, [documents])} end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:logs, :events])
      |> Keyword.put(:mysql, mysql)
    )

    assert {:ok, %{"results" => [event_row]}} =
             SRQL.query("in:events time:last_1h limit:1", %{scope: events_scope})

    assert event_row["metadata"] == %{"security_signal" => %{"finding_uid" => "finding-0001"}}
    assert event_row["unmapped"] == %{}
    assert event_row["device"] == nil
    # One undecodable document is kept as it was; the row still renders.
    assert event_row["observables"] == "not json"

    assert {:ok, %{"results" => [log_row]}} =
             SRQL.query("in:logs time:last_1h limit:1", %{scope: logs_scope})

    assert log_row["metadata"] == ~s({"security_signal":{"finding_uid":"finding-0001"}})

    assert {:ok, %{payload: payload}} =
             SRQL.query_arrow("in:events time:last_1h limit:1", %{scope: events_scope})

    assert is_binary(payload)
  end

  test "single warehouse aggregates retain their column names", %{prev: prev} do
    mysql = fn _sql ->
      {:ok, postgrex_result(["unique_talkers"], [[2]])}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev |> Keyword.put(:cutover_datasets, [:flows]) |> Keyword.put(:mysql, mysql)
    )

    assert {:ok, %{"results" => [%{"unique_talkers" => 2}]}} =
             SRQL.query(
               ~s|in:flows time:last_1h stats:"count_distinct(src_endpoint_ip) as unique_talkers"|,
               %{scope: @scope}
             )
  end

  test "whole-hour charts read the hourly rollup when the MV is fresh", %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:mysql, flows_probes(1_800))
    )

    assert {:ok, %{"results" => [_row], "error" => nil}} =
             SRQL.query(
               "in:flows time:last_7d bucket:1h agg:sum value_field:bytes_total",
               %{scope: @scope}
             )

    assert_received {:starrocks_query, body}
    assert body =~ "FROM serviceradar.ocsf_network_activity_hourly"
    assert hour_aligned_bounds?(body)
  end

  test "whole-hour charts fall back to raw StarRocks tables when the MV is stale",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:mysql, flows_probes(14_400))
    )

    assert {:ok, %{"results" => [_row], "error" => nil}} =
             SRQL.query(
               "in:flows time:last_7d bucket:1h agg:sum value_field:bytes_total",
               %{scope: @scope}
             )

    assert_received {:starrocks_query, body}
    assert body =~ "FROM serviceradar.ocsf_network_activity"
    refute body =~ "_hourly"
    # `last_7d` runs from `now - 7d` to `now`, so neither edge lands on an hour.
    # The gate swapped the source underneath this query; it must not also move
    # the window it scores, or the chart's edge bars change value with no error.
    assert hour_aligned_bounds?(body)
  end

  defp hour_aligned_bounds?(sql) do
    Enum.all?([~r/>= '([^']+)'/, ~r/< '([^']+)'/], fn pattern ->
      [_, bound] = Regex.run(pattern, sql)
      {:ok, at, _} = DateTime.from_iso8601(bound)
      at.minute == 0 and at.second == 0
    end)
  end

  defmodule MapSliceStub do
    @moduledoc false

    def query(query, %{scope: scope}) do
      with :ok <- ServiceRadarWebNG.SRQL.EntityAccess.authorize(query, scope) do
        send(scope.test_pid, {:map_slice_query, query})

        rows =
          if String.contains?(query, " by src_endpoint_ip,dst_endpoint_ip") do
            [
              %{
                "src_endpoint_ip" => "192.0.2.10",
                "dst_endpoint_ip" => "198.51.100.20",
                "bytes_total" => 1200,
                "packets_total" => 15,
                "flow_count" => 7
              }
            ]
          else
            [%{"bytes_total" => 1200, "packets_total" => 15, "flow_count" => 7}]
          end

        {:ok, %{"results" => rows}}
      end
    end
  end

  test "dashboard map follows the flows cutover without an explicit srql_module",
       %{prev: prev} do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :cutover_datasets, [:flows])
    )

    prev_srql = Application.get_env(:serviceradar_web_ng, :srql_module)
    Application.put_env(:serviceradar_web_ng, :srql_module, MapSliceStub)

    on_exit(fn ->
      if is_nil(prev_srql) do
        Application.delete_env(:serviceradar_web_ng, :srql_module)
      else
        Application.put_env(:serviceradar_web_ng, :srql_module, prev_srql)
      end
    end)

    scope = %{permissions: MapSet.new(["observability.netflow.view"]), test_pid: self()}
    window = Window.resolve("last_1h", "netflow")

    slice = Data.load_netflow_map(scope, window: window)

    assert [link] = slice.traffic_links
    assert link.src_endpoint_ip == "192.0.2.10"
    assert link.dst_endpoint_ip == "198.51.100.20"
    assert link.bytes == 1200
    assert link.geo_mapped == false
    assert link.geo_from == nil
    assert link.geo_to == nil
    assert slice.flow_summary.flow_count == 7
    assert slice.netflow_state == :active
    assert slice.map_empty_title == "Flows are not mapped yet"

    assert slice.map_empty_detail ==
             "Recent conversations need coordinates on both ends. Enable GeoIP, add Local CIDR map anchors, or wait for ipinfo/GeoLite enrichment."

    window_stat = Enum.find(slice.map_stats, &(&1.label == "Window"))
    assert window_stat.value == "Last hour"
    assert window_stat.href =~ "time%3Alast_1h"

    conversations = Enum.find(slice.map_stats, &(&1.label == "Conversations"))
    assert conversations.value == "1"
    flow_records = Enum.find(slice.map_stats, &(&1.label == "Flow Records"))
    assert flow_records.value == "7"
    traffic = Enum.find(slice.map_stats, &(&1.label == "Traffic"))
    assert traffic.value == "1.2 KiB"

    assert_received {:map_slice_query, flows_query}
    assert flows_query =~ "in:flows"
  end

  test "fullscreen map overlay becomes an error when the SRQL load exits" do
    empty = Data.empty()

    socket =
      Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, %{
        netflow_state: :loading,
        map_stats: empty.map_stats,
        traffic_links_window_label: empty.traffic_links_window_label,
        topology_links: empty.topology_links,
        topology_links_json: empty.topology_links_json,
        traffic_links: empty.traffic_links,
        traffic_links_json: empty.traffic_links_json,
        mtr_overlays: empty.mtr_overlays,
        mtr_overlays_json: empty.mtr_overlays_json,
        map_empty_title: empty.map_empty_title,
        map_empty_detail: empty.map_empty_detail
      })

    assert socket.assigns.map_empty_title == "Checking traffic sources"

    {:noreply, socket} =
      ServiceRadarWebNGWeb.MapLive.NetflowMap.handle_async(
        :netflow_map_load,
        {:exit, {:timeout, :starrocks}},
        socket
      )

    assert socket.assigns.netflow_state == :error
    assert socket.assigns.traffic_links == []
    assert socket.assigns.traffic_links_json == "[]"
    assert socket.assigns.map_empty_title == "Unable to load NetFlow map"
    assert socket.assigns.map_empty_detail == "Select a time window to retry the query."
  end

  describe "Horizon StarRocks-only SRQL entities" do
    @horizon_events_scope %{permissions: MapSet.new(["observability.events.view"])}
    @horizon_traces_scope %{permissions: MapSet.new(["observability.traces.view"])}

    test "refuse with :starrocks_required when StarRocks is disabled and :forbidden when unauthorized",
         %{prev: prev} do
      mysql = fn sql -> flunk("disabled StarRocks must not execute SQL: #{sql}") end

      Application.put_env(
        :serviceradar_core,
        StarRocks,
        prev
        |> Keyword.put(:enabled, false)
        |> Keyword.put(:mysql, mysql)
      )

      for {query, authorized_scope, unauthorized_scope} <- [
            {"in:horizon_outages time:last_1h limit:5", @horizon_events_scope, @horizon_traces_scope},
            {"in:horizon_bgp time:last_1h limit:5", @horizon_events_scope, @horizon_traces_scope},
            {"in:horizon_zombies time:last_1h limit:5", @horizon_events_scope, @horizon_traces_scope},
            {"in:horizon_paths time:last_1h limit:5", @horizon_traces_scope, @horizon_events_scope}
          ] do
        assert {:error, :forbidden} = SRQL.query(query, %{scope: unauthorized_scope})
        assert {:error, :starrocks_required} = SRQL.query(query, %{scope: authorized_scope})

        # Caller-supplied mode must not bypass server-side backend refusal.
        assert {:error, :starrocks_required} =
                 SRQL.query(query, %{scope: authorized_scope, mode: "starrocks"})
      end
    end

    test "compile via the Rust NIF and execute StarRocks SQL with viz metadata when StarRocks is enabled",
         %{prev: prev} do
      parent = self()

      mysql = fn sql ->
        send(parent, {:starrocks_query, sql})

        cond do
          sql =~ "serviceradar.horizon_outages" ->
            {:ok, postgrex_result(["outage_id", "status", "origin_asn"], [["out-900", "active", 64_500]])}

          sql =~ "serviceradar.horizon_bgp_events" ->
            {:ok, postgrex_result(["event_id", "kind", "prefix"], [["bgp-900", "watchlist", "198.51.100.0/24"]])}

          sql =~ "serviceradar.horizon_bgp_zombies" ->
            {:ok, postgrex_result(["episode_id", "is_beacon", "divergence_pct"], [["ep-900", 1, 35.5]])}

          sql =~ "serviceradar.horizon_path_hops" ->
            {:ok, postgrex_result(["target_id", "hop_ttl", "is_cloud"], [["tgt-900", 4, 1]])}
        end
      end

      Application.put_env(
        :serviceradar_core,
        StarRocks,
        prev
        |> Keyword.put(:enabled, true)
        |> Keyword.put(:cutover_datasets, [])
        |> Keyword.put(:mysql, mysql)
      )

      assert {:ok, %{"results" => [outage], "viz" => outage_viz, "error" => nil}} =
               SRQL.query(
                 "in:horizon_outages status:active covering_prefix:198.51.100.0/24 origin_asn:64500 time:last_24h limit:10",
                 %{scope: @horizon_events_scope, mode: "cnpg"}
               )

      assert outage["outage_id"] == "out-900"
      assert is_map(outage_viz) and outage_viz["columns"] != []
      assert_received {:starrocks_query, outage_sql}
      assert outage_sql =~ "FROM serviceradar.horizon_outages"
      assert outage_sql =~ "`status` = 'active'"
      assert outage_sql =~ "`covering_prefix` = '198.51.100.0/24'"
      assert outage_sql =~ "`origin_asn` = 64500"

      assert {:ok, %{"results" => [bgp], "viz" => bgp_viz, "error" => nil}} =
               SRQL.query(
                 "in:horizon_bgp kind:(hijack,watchlist) prefix:198.51.100.0/24 time:last_24h limit:10",
                 %{scope: @horizon_events_scope}
               )

      assert bgp["event_id"] == "bgp-900"
      assert is_map(bgp_viz) and bgp_viz["columns"] != []
      assert_received {:starrocks_query, bgp_sql}
      assert bgp_sql =~ "FROM serviceradar.horizon_bgp_events"
      assert bgp_sql =~ "`kind` IN ('hijack', 'watchlist')"

      assert {:ok, %{"results" => [zombie], "viz" => zombie_viz, "error" => nil}} =
               SRQL.query(
                 "in:horizon_zombies status:active is_beacon:true divergence_pct:>=25.5 time:last_24h limit:10",
                 %{scope: @horizon_events_scope}
               )

      assert zombie["episode_id"] == "ep-900"
      assert is_map(zombie_viz) and zombie_viz["columns"] != []
      assert_received {:starrocks_query, zombie_sql}
      assert zombie_sql =~ "FROM serviceradar.horizon_bgp_zombies"
      assert zombie_sql =~ "`is_beacon` = TRUE"
      assert zombie_sql =~ "`divergence_pct` >= 25.5"

      assert {:ok, %{"results" => [hop], "viz" => hop_viz, "error" => nil}} =
               SRQL.query(
                 "in:horizon_paths target_id:tgt-900 is_cloud:true mtu_blackhole_detected:false sort:hop_ttl:asc limit:10",
                 %{scope: @horizon_traces_scope}
               )

      assert hop["target_id"] == "tgt-900"
      assert is_map(hop_viz) and hop_viz["columns"] != []
      assert_received {:starrocks_query, hop_sql}
      assert hop_sql =~ "FROM serviceradar.horizon_path_hops"
      assert hop_sql =~ "`is_cloud` = TRUE"
      assert hop_sql =~ "`mtu_blackhole_detected` = FALSE"
      assert hop_sql =~ "`hop_ttl` ASC"
    end

    test "rejects unsupported Horizon filters, clauses, and direct non-StarRocks NIF translation",
         %{prev: prev} do
      mysql = fn sql -> flunk("invalid Horizon query must not execute SQL: #{sql}") end

      Application.put_env(
        :serviceradar_core,
        StarRocks,
        prev
        |> Keyword.put(:enabled, true)
        |> Keyword.put(:mysql, mysql)
      )

      assert {:error, msg} =
               SRQL.query("in:horizon_outages prefix:198.51.100.0/24 limit:5", %{
                 scope: @horizon_events_scope
               })

      assert to_string(msg) =~ "prefix"

      assert {:error, _} =
               SRQL.query("in:horizon_bgp unknown_field:abc limit:5", %{
                 scope: @horizon_events_scope
               })

      assert {:error, _} =
               SRQL.query("in:horizon_zombies stats:count() as n", %{
                 scope: @horizon_events_scope
               })

      assert {:error, _} =
               SRQL.query("in:horizon_paths bucket:5m", %{
                 scope: @horizon_traces_scope
               })

      for entity <- ~w(horizon_outages horizon_bgp horizon_zombies horizon_paths) do
        assert {:error, reason} =
                 ServiceRadarSRQL.Native.translate("in:#{entity} limit:5", nil, nil, nil, nil)

        assert to_string(reason) =~ "StarRocks"
      end
    end
  end

  defp postgrex_result(columns, rows) do
    %Postgrex.Result{
      command: :select,
      columns: columns,
      rows: rows,
      num_rows: length(rows),
      connection_id: nil
    }
  end

  # Answers the rollup gate's two high-water-mark probes and forwards every
  # other statement to the {:starrocks_query, _} assertions, which pin the
  # executed data statement. `mv_lag_seconds` is how far the view trails the
  # table it aggregates; both marks sit an hour in the past, so a test that
  # passes here cannot be passing on wall-clock age. Lag is compared on the
  # hour grain, so the stale case is set a clear multiple of an hour beyond
  # the threshold rather than a hair over it.
  defp flows_probes(mv_lag_seconds) do
    raw_max =
      NaiveDateTime.utc_now() |> NaiveDateTime.add(-3_600) |> NaiveDateTime.truncate(:second)

    mv_max = NaiveDateTime.add(raw_max, -mv_lag_seconds)

    # Marks come back as the Frontend's text-protocol cells, not structs.
    fn
      "SELECT IS_ACTIVE," <> _ ->
        {:ok, %{rows: [["true", "SUCCESS", 15]]}}

      "SELECT MAX(`bucket`) FROM serviceradar.ocsf_network_activity_hourly WHERE " <> _ ->
        {:ok, postgrex_result(["max"], [[NaiveDateTime.to_string(mv_max)]])}

      "SELECT MAX(`time`) FROM serviceradar.ocsf_network_activity WHERE " <> _ ->
        {:ok, postgrex_result(["max"], [[NaiveDateTime.to_string(raw_max)]])}

      sql ->
        send(self(), {:starrocks_query, sql})
        {:ok, postgrex_result(["timestamp", "value"], [["1999-06-15 12:00:00", 1200]])}
    end
  end
end
