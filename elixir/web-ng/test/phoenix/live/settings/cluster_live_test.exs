defmodule ServiceRadarWebNGWeb.Settings.ClusterLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.AgentTracker
  alias ServiceRadarWebNG.AccountsFixtures

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    %{conn: log_in_user(conn, user)}
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
end
