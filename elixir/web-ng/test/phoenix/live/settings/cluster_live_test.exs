defmodule ServiceRadarWebNGWeb.Settings.ClusterLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.AgentTracker
  alias ServiceRadarWebNG.AccountsFixtures

  defmodule StubIngestionLanes do
    @moduledoc false
    def stats do
      if pid = Application.get_env(:serviceradar_web_ng, :ingestion_lanes_test_pid),
        do: send(pid, :ingestion_lane_stats_requested)

      Application.get_env(:serviceradar_web_ng, :ingestion_lanes_test_result, {:error, :unavailable})
    end
  end

  setup %{conn: conn} do
    previous =
      Map.new(
        [:ingestion_lanes, :ingestion_lanes_test_pid, :ingestion_lanes_test_result],
        &{&1, Application.fetch_env(:serviceradar_web_ng, &1)}
      )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:serviceradar_web_ng, key, value)
        {key, :error} -> Application.delete_env(:serviceradar_web_ng, key)
      end)
    end)

    Application.put_env(:serviceradar_web_ng, :ingestion_lanes, StubIngestionLanes)
    user = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, user)}
  end

  test "the Ingestion card shows each lane's depth against its capacity", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :ingestion_lanes_test_result,
      {:ok,
       [
         %{lane: "sweep", depth: 3, in_flight: 2, bytes: 0, capacity: 512, rejected: 4, nacked: 0, incomplete_runs: 0},
         %{lane: "sync", depth: 0, in_flight: 0, bytes: 0, capacity: 256, rejected: 0, nacked: 0, incomplete_runs: 1}
       ]}
    )

    {:ok, view, _html} = live(conn, ~p"/settings/cluster")

    assert view |> element("#ingestion-lane-sweep") |> render() =~ "3 / 512"
    assert view |> element("#ingestion-lane-sweep") |> render() =~ "4"
    assert view |> element("#ingestion-lane-sync") |> render() =~ "0 / 256"
    assert has_element?(view, ~s|a[href="/dashboard/ingestion-lanes"]|)
  end

  test "the Ingestion card says so when no core node reports lane stats", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :ingestion_lanes_test_result, {:error, :unavailable})

    {:ok, view, _html} = live(conn, ~p"/settings/cluster")

    assert has_element?(view, "#ingestion-lanes-unavailable")
    refute has_element?(view, "#ingestion-lane-sweep")
  end

  test "lane stats are requested on the connected render and each refresh, not the static one", %{
    conn: conn
  } do
    Application.put_env(:serviceradar_web_ng, :ingestion_lanes_test_pid, self())

    static_html = conn |> get(~p"/settings/cluster") |> html_response(200)
    assert static_html =~ "Loading lane stats"
    refute_received :ingestion_lane_stats_requested

    {:ok, view, _html} = live(conn, ~p"/settings/cluster")
    assert_received :ingestion_lane_stats_requested

    send(view.pid, :refresh)
    _ = render(view)
    assert_received :ingestion_lane_stats_requested
  end

  test "renders connected agent runtime metadata", %{conn: conn} do
    agent_id = "agent-runtime-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      AgentTracker.remove_agent(agent_id)
    end)

    :ok =
      AgentTracker.track_agent(agent_id, %{
        service_count: 7,
        partition: "edge-a",
        source_ip: "10.0.0.21",
        gateway_id: "gateway-demo",
        version: "1.2.10",
        hostname: "dusk01",
        os: "linux",
        arch: "amd64"
      })

    {:ok, _lv, html} = live(conn, ~p"/settings/cluster")

    assert html =~ "Connected Agents"
    assert html =~ agent_id
    assert html =~ "dusk01"
    assert html =~ "1.2.10"
    assert html =~ "linux/amd64"
    assert html =~ "gateway-demo"
    assert html =~ "edge-a"
  end

  test "shows explicit placeholders when runtime metadata is unavailable", %{conn: conn} do
    agent_id = "agent-runtime-missing-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      AgentTracker.remove_agent(agent_id)
    end)

    :ok =
      AgentTracker.track_agent(agent_id, %{
        service_count: 1,
        source_ip: "10.0.0.55"
      })

    {:ok, _lv, html} = live(conn, ~p"/settings/cluster")

    assert html =~ agent_id
    assert html =~ "Unknown version"
    assert html =~ "Unknown platform"
    assert html =~ "Unknown gateway"
    assert html =~ "Partition unknown"
  end

  test "refresh reconciles connected-agent metadata from tracker snapshot", %{conn: conn} do
    agent_id = "agent-runtime-refresh-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      AgentTracker.remove_agent(agent_id)
    end)

    :ok =
      AgentTracker.track_agent(agent_id, %{
        service_count: 1,
        gateway_id: "gateway-demo",
        partition: "default"
      })

    {:ok, view, html} = live(conn, ~p"/settings/cluster")

    assert html =~ agent_id
    assert html =~ "Unknown version"
    assert html =~ "Unknown platform"

    updated_agent =
      agent_id
      |> AgentTracker.get_agent()
      |> Map.merge(%{
        version: "1.2.19",
        hostname: "agent-refresh-host",
        os: "linux",
        arch: "amd64"
      })

    true = :ets.insert(:agent_tracker, {agent_id, updated_agent})

    send(view.pid, :refresh)
    refreshed_html = render(view)

    assert refreshed_html =~ "1.2.19"
    assert refreshed_html =~ "linux/amd64"
    assert refreshed_html =~ "agent-refresh-host"
  end

  test "renders gateway replicas as distinct instances when they share a logical gateway id", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/settings/cluster")

    refute html =~ "3 instance(s) across 1 logical gateway(s)"

    send(
      view.pid,
      {:gateway_registered,
       %{
         gateway_id: "gateway-platform",
         partition: "default",
         node: :"serviceradar_agent_gateway@10.42.199.12",
         status: :available,
         last_heartbeat: DateTime.utc_now()
       }}
    )

    send(
      view.pid,
      {:gateway_registered,
       %{
         gateway_id: "gateway-platform",
         partition: "default",
         node: :"serviceradar_agent_gateway@10.42.199.45",
         status: :available,
         last_heartbeat: DateTime.utc_now()
       }}
    )

    send(
      view.pid,
      {:gateway_registered,
       %{
         gateway_id: "gateway-platform",
         partition: "default",
         node: :"serviceradar_agent_gateway@10.42.202.248",
         status: :available,
         last_heartbeat: DateTime.utc_now()
       }}
    )

    updated_html = render(view)

    assert updated_html =~ "3 instance(s) across 1 logical gateway(s)"
    assert updated_html =~ "gateway-platform"
    assert updated_html =~ "serviceradar_agent_gateway@10.42.199.12"
    assert updated_html =~ "serviceradar_agent_gateway@10.42.199.45"
    assert updated_html =~ "serviceradar_agent_gateway@10.42.202.248"
  end

  test "periodic refresh drops gateway instances that are no longer authoritative", %{conn: conn} do
    gateway_id = "gateway-refresh-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(conn, ~p"/settings/cluster")

    send(
      view.pid,
      {:gateway_registered,
       %{
         gateway_id: gateway_id,
         partition: "default",
         node: :"serviceradar_agent_gateway@10.42.199.12",
         status: :available,
         last_heartbeat: DateTime.utc_now()
       }}
    )

    stale_html = render(view)
    assert stale_html =~ gateway_id

    send(view.pid, :refresh)
    refreshed_html = render(view)

    refute refreshed_html =~ gateway_id
  end

  @tag :web_ng_shared_fixture_db
  test "the static render runs no Oban queue query; the connected render does", %{conn: conn} do
    test_pid = self()
    handler_id = {__MODULE__, :oban_query, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:service_radar, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if metadata[:source] == "oban_jobs", do: send(test_pid, {:oban_jobs_query, self()})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # The static render is discarded as soon as the socket connects.
    conn = get(conn, ~p"/settings/cluster")
    assert html_response(conn, 200) =~ "Cluster Status"
    refute_received {:oban_jobs_query, _}

    {:ok, _view, _html} = live(conn, ~p"/settings/cluster")
    assert_received {:oban_jobs_query, _}
  end

  @tag :web_ng_shared_fixture_db
  test "an agent heartbeat updates only that agent's row", %{conn: conn} do
    steady_id = "agent-heartbeat-steady-#{System.unique_integer([:positive])}"
    pushing_id = "agent-heartbeat-pushing-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      AgentTracker.remove_agent(steady_id)
      AgentTracker.remove_agent(pushing_id)
    end)

    :ok = AgentTracker.track_agent(steady_id, %{service_count: 2, hostname: "host01.example.com"})
    :ok = AgentTracker.track_agent(pushing_id, %{service_count: 3, hostname: "host02.example.com"})

    {:ok, view, _html} = live(conn, ~p"/settings/cluster")
    assert has_element?(view, "#cluster-agent-#{steady_id}")
    assert has_element?(view, "#cluster-agent-#{pushing_id}")

    send(
      view.pid,
      {:agent_status,
       %{
         agent_id: pushing_id,
         service_count: 9,
         hostname: "host02.example.com",
         last_seen: DateTime.utc_now()
       }}
    )

    assert has_element?(view, "#cluster-agent-#{pushing_id}", "9")
    assert has_element?(view, "#cluster-agent-#{steady_id}", "2")

    # A heartbeat from an agent the page has not seen adds exactly one row.
    new_id = "agent-heartbeat-new-#{System.unique_integer([:positive])}"
    send(view.pid, {:agent_status, %{agent_id: new_id, service_count: 1, last_seen: DateTime.utc_now()}})

    assert has_element?(view, "#cluster-agent-#{new_id}")

    rows =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s(#cluster-agents tr[id^="cluster-agent-agent-heartbeat-"]))

    assert Enum.count(rows) == 3
  end
end
