defmodule ServiceRadarWebNGWeb.AnalyticsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "analytics page hides SRQL query bar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/analytics")

    refute has_element?(view, "form[phx-change='srql_change']")
  end
end
