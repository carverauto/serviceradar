defmodule ServiceRadarWebNGWeb.AnalyticsLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "analytics page hides SRQL query bar", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNGWeb.AnalyticsLiveTest.AnalyticsMockSRQL
    )

    {:ok, view, _html} = live(conn, ~p"/analytics")

    refute has_element?(view, "form[phx-change='srql_change']")
  after
    Application.delete_env(:serviceradar_web_ng, :srql_module)
  end
end

defmodule ServiceRadarWebNGWeb.AnalyticsLiveTest.AnalyticsMockSRQL do
  @behaviour ServiceRadarWebNG.SRQLBehaviour

  @impl true
  def query(_query, _opts \\ %{}) do
    {:ok, %{"results" => []}}
  end
end
