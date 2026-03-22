defmodule ServiceRadarWebNGWeb.TopologyLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  setup do
    previous_flag = Application.get_env(:serviceradar_web_ng, :god_view_enabled)
    previous_gate_env = System.get_env("SERVICERADAR_MIGRATIONS_GATE")

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)
    System.put_env("SERVICERADAR_MIGRATIONS_GATE", "false")

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :god_view_enabled, previous_flag)

      if is_nil(previous_gate_env) do
        System.delete_env("SERVICERADAR_MIGRATIONS_GATE")
      else
        System.put_env("SERVICERADAR_MIGRATIONS_GATE", previous_gate_env)
      end
    end)

    :ok
  end

  test "shows empty topology copy when the stream is healthy but has no graph data", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/topology")

    html =
      render_hook(view, "god_view_stream_stats", %{
        "node_count" => 0,
        "edge_count" => 0,
        "pipeline_stats" => %{}
      })

    assert html =~ "No topology data yet"
    assert html =~ "Run discovery or mapper jobs to populate graph relations."
    refute html =~ "Topology unavailable"
  end

  test "keeps topology unavailable copy when the stream errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/topology")

    html = render_hook(view, "god_view_stream_error", %{})

    assert html =~ "Topology unavailable"
    assert html =~ "The topology stream failed."
  end

  test "endpoint layer toggle only changes the endpoints control state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/topology")

    assert html =~ ~s(phx-value-layer="endpoints")
    assert html =~ ~s(phx-value-layer="backbone")
    assert html =~ ~s(btn btn-xs btn-primary h-7 min-h-7)

    html = render_click(element(view, ~s(button[phx-value-layer="endpoints"])))

    assert html =~ ~s(phx-value-layer="endpoints")
    assert html =~ ~s(btn btn-xs btn-ghost h-7 min-h-7)
    assert html =~ ~s(phx-value-layer="backbone")
    assert html =~ ~s(btn btn-xs btn-primary h-7 min-h-7)
  end
end
