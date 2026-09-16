defmodule ServiceRadarWebNG.SRQLStarRocksModeTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNG.SRQL

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

    http = fn request ->
      send(parent, {:starrocks_query, request.body})

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "meta" => [%{"name" => "id"}, %{"name" => "bytes_in"}],
             "data" => [["flow-alpha-0001", 1200]]
           })
       }}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:query_http, http)
    )

    assert {:ok, %{"results" => [row], "error" => nil}} =
             SRQL.query(@flows_query, %{scope: @scope})

    assert row["id"] == "flow-alpha-0001"
    assert row["bytes_in"] == 1200
    assert_received {:starrocks_query, body}
    assert body =~ "ocsf_network_activity"
    refute body =~ "time_bucket"

    assert {:error, :forbidden} =
             SRQL.query(@flows_query, %{scope: %{permissions: MapSet.new()}})
  end

  test "authorized last_1h map stats select StarRocks when flows are in cutover_datasets",
       %{prev: prev} do
    parent = self()

    http = fn request ->
      send(parent, {:starrocks_query, request.body})

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "meta" => [
               %{"name" => "bytes_total"},
               %{"name" => "src_endpoint_ip"},
               %{"name" => "dst_endpoint_ip"}
             ],
             "data" => [[1200, "192.0.2.10", "198.51.100.20"]]
           })
       }}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:query_http, http)
    )

    window = ServiceRadarWebNGWeb.DashboardLive.Window.resolve("last_1h", "netflow")
    query = ServiceRadarWebNGWeb.DashboardLive.Data.NetflowTraffic.srql_query(window)

    assert {:ok, %{"results" => [row], "error" => nil}} =
             SRQL.query(query, %{scope: @scope})

    assert row["bytes_total"] == 1200
    assert_received {:starrocks_query, body}
    assert body =~ "ocsf_network_activity"
    assert body =~ "GROUP BY src_endpoint_ip,dst_endpoint_ip"
    refute body =~ "time_bucket"
  end

  test "explicit mode=starrocks executes after authorization without cutting over", %{prev: prev} do
    http = fn request ->
      send(self(), {:starrocks_query, request.body})

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "meta" => [%{"name" => "id"}, %{"name" => "bytes_in"}],
             "data" => [["flow-alpha-0001", 1200]]
           })
       }}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(prev, :query_http, http)
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

    http = fn request ->
      send(parent, {:starrocks_query, request.body})

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "meta" => [%{"name" => "device_id"}, %{"name" => "value"}],
             "data" => [["sr:host-alpha", 42.0]]
           })
       }}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:metrics])
      |> Keyword.put(:query_http, http)
    )

    assert {:ok, %{"results" => [row], "error" => nil}} =
             SRQL.query("in:timeseries_metrics time:last_1h limit:1", %{scope: scope})

    assert row["device_id"] == "sr:host-alpha"
    assert_received {:starrocks_query, body}
    assert body =~ "timeseries_metrics"
    refute body =~ "platform.timeseries_metrics"
  end

  test "attributed flow queries error when the JDBC catalog is disabled", %{prev: prev} do
    http = fn _request ->
      flunk("catalog-disabled attributed_flows must not call StarRocks HTTP")
    end

    Application.put_env(
      :serviceradar_core,
      ServiceRadar.Analytics.StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:query_http, http)
    )

    assert {:error, {:starrocks_catalog_disabled, "cnpg_platform"}} =
             SRQL.query("in:attributed_flows time:last_1h limit:1", %{scope: @scope})
  end

  test "attributed flow queries execute catalog joins when the catalog is enabled",
       %{prev: prev} do
    parent = self()

    http = fn request ->
      send(parent, {:starrocks_query, request.body})

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "meta" => [%{"name" => "id"}, %{"name" => "comm"}],
             "data" => [["flow-alpha-0001", "sshd"]]
           })
       }}
    end

    Application.put_env(
      :serviceradar_core,
      ServiceRadar.Analytics.StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:flows])
      |> Keyword.put(:catalog_enabled, true)
      |> Keyword.put(:query_http, http)
    )

    assert {:ok, %{"results" => [row], "error" => nil}} =
             SRQL.query("in:attributed_flows time:last_1h limit:1", %{scope: @scope})

    assert row["id"] == "flow-alpha-0001"
    assert_received {:starrocks_query, body}
    assert body =~ "cnpg_platform.platform.flow_process_attribution_current"
    refute body =~ "platform.ocsf_network_activity"
    refute body =~ "network_credential_secrets"
  end

  test "authorized log and event queries execute StarRocks SQL when those datasets are cut over",
       %{prev: prev} do
    parent = self()
    logs_scope = %{permissions: MapSet.new(["observability.logs.view"])}
    events_scope = %{permissions: MapSet.new(["observability.events.view"])}

    http = fn request ->
      send(parent, {:starrocks_query, request.body})

      {:ok,
       %{
         status: 200,
         body:
           Jason.encode!(%{
             "meta" => [%{"name" => "id"}, %{"name" => "severity"}],
             "data" => [["row-alpha-0001", "low"]]
           })
       }}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev
      |> Keyword.put(:cutover_datasets, [:logs, :events])
      |> Keyword.put(:query_http, http)
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
end
