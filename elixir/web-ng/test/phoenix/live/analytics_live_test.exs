defmodule ServiceRadarWebNGWeb.AnalyticsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  @moduletag :web_ng_shared_fixture_db

  setup :register_and_log_in_user

  test "analytics route mounts the dashboard creator", %{conn: conn} do
    conn = get(conn, ~p"/analytics")

    assert html_response(conn, 200) =~ "Dashboard Creator"
  end
end
