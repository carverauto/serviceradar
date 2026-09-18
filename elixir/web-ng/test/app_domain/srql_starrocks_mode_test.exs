defmodule ServiceRadarWebNG.SRQLStarRocksModeTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNG.SRQL
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

  test "authorized flow queries stay on CNPG while cutover_datasets is empty" do
    result =
      try do
        SRQL.query(@flows_query, %{scope: @scope})
      rescue
        exception -> {:rescued, exception}
      end

    refute match?({:error, :connect_failed}, result)
    assert match?({:rescued, %RuntimeError{message: "could not lookup Ecto repo" <> _}}, result)
  end

  test "authorized flow queries execute compiled StarRocks SQL when cutover_datasets lists flows",
       %{prev: prev} do
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

    assert {:error, :forbidden} =
             SRQL.query(@flows_query, %{scope: %{permissions: MapSet.new()}})
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

  test "explicit mode=starrocks executes after authorization without cutting over", %{prev: prev} do
    mysql = fn sql ->
      send(self(), {:starrocks_query, sql})
      {:ok, postgrex_result(["id", "bytes_in"], [["flow-alpha-0001", 1200]])}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :mysql, mysql)
    )

    assert {:ok, %{"results" => [row]}} =
             SRQL.query(@flows_query, %{scope: @scope, mode: "starrocks"})

    assert row["id"] == "flow-alpha-0001"
    assert row["bytes_in"] == 1200
    assert_received {:starrocks_query, body}
    assert body =~ "FROM serviceradar.ocsf_network_activity"
  end

  test "authorized timeseries queries execute StarRocks SQL when metrics are in cutover_datasets",
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
      |> Keyword.put(:cutover_datasets, [:metrics])
      |> Keyword.put(:mysql, mysql)
    )

    assert {:ok, %{"results" => [row], "error" => nil}} =
             SRQL.query("in:timeseries_metrics time:last_1h limit:1", %{scope: scope})

    assert row["device_id"] == "sr:host-alpha"
    assert_received {:starrocks_query, body}
    assert body =~ "timeseries_metrics"
    refute body =~ "platform.timeseries_metrics"
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

    slice = ServiceRadarWebNGWeb.DashboardLive.Data.load_netflow_map(scope, window: window)

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
    empty = ServiceRadarWebNGWeb.DashboardLive.Data.empty()

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

  defp postgrex_result(columns, rows) do
    %Postgrex.Result{
      command: :select,
      columns: columns,
      rows: rows,
      num_rows: length(rows),
      connection_id: nil
    }
  end
end
