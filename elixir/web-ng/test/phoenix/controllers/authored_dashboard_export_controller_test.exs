defmodule ServiceRadarWebNGWeb.AuthoredDashboardExportControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Dashboards

  @moduletag :web_ng_shared_fixture_db

  setup %{conn: conn} do
    user = admin_user_fixture()
    scope = Scope.for_user(user)

    {:ok, dashboard} =
      Dashboards.create_authored_dashboard(scope, %{title: "Export errors #{System.unique_integer([:positive])}"})

    {:ok, panel} =
      Dashboards.create_panel(scope, %{
        dashboard_id: dashboard.id,
        title: "Services",
        srql_query: "in:services limit:5",
        visual_type: :table,
        position: 0
      })

    %{conn: log_in_user(conn, user), dashboard: dashboard, panel: panel}
  end

  test "a malformed vars parameter is not echoed and the error is plain text", %{
    conn: conn,
    dashboard: dashboard,
    panel: panel
  } do
    markup = "<img src=x onerror=alert(1)>"

    conn = get(conn, ~p"/dashboard/#{dashboard.id}/panels/#{panel.id}/export.csv", %{"vars" => markup})

    assert conn.status == 422
    assert ["text/plain" <> _charset] = get_resp_header(conn, "content-type")
    assert conn.resp_body == "Could not export panel CSV"
  end
end
