defmodule ServiceRadarWebNGWeb.AnalyticsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  setup :register_and_log_in_user

  test "legacy analytics route redirects to the operations dashboard", %{conn: conn} do
    conn = get(conn, ~p"/analytics")

    assert redirected_to(conn) == ~p"/dashboard"
  end
end
