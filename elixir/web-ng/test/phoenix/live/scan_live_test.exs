defmodule ServiceRadarWebNGWeb.ScanLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()
    %{conn: log_in_user(conn, user)}
  end

  test "renders the ad-hoc scan console for an authorized user", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/scans")

    assert html =~ "Ad-hoc Network Scan"
    assert html =~ "Egress agent"
    assert html =~ "Run scan"
  end

  test "validate reports valid and invalid target counts", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scans")

    html =
      render_change(view, "validate", %{
        "scan" => %{"targets" => "10.0.0.1\nnot-an-ip\n10.0.0.2"}
      })

    assert html =~ "2 valid"
    assert html =~ "1 invalid"
  end

  test "run_scan without a mode surfaces a validation error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scans")

    html =
      render_submit(view, "run_scan", %{
        "scan" => %{
          "targets" => "10.0.0.1",
          "agent_id" => "agent-1",
          "mode_icmp" => "false",
          "mode_tcp" => "false",
          "mode_mtr" => "false"
        }
      })

    assert html =~ "Select at least one scan mode"
  end
end
