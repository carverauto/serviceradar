defmodule ServiceRadarWebNGWeb.LogLive.NetflowsTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  use ServiceRadarWebNG.AshTestHelpers

  alias ServiceRadarWebNG.AccountsFixtures

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)

    Application.put_env(
      :serviceradar_web_ng,
      :srql_module,
      ServiceRadarWebNG.TestSupport.SRQLStub
    )

    on_exit(fn ->
      Application.delete_env(:serviceradar_web_ng, :srql_module)
    end)

    %{conn: conn}
  end

  test "direction chips patch the SRQL query", %{conn: conn} do
    q = "in:flows time:last_24h"
    {:ok, lv, html} = live(conn, ~p"/netflows?#{%{q: q, limit: 50}}")

    assert html =~ "Direction"
    assert has_element?(lv, "a", "Internal")
    assert has_element?(lv, "a", "Outbound")
    assert has_element?(lv, "a", "Inbound")
    assert has_element?(lv, "a", "External")

    lv
    |> element("a[data-phx-link='patch']", "Internal")
    |> render_click()

    expected_query = "#{q} direction:internal"

    # Preserve ordering by using a keyword list; the LiveView builds the query in this order.
    expected_path =
      "/netflows?" <>
        Plug.Conn.Query.encode(
          tab: "netflows",
          limit: 50,
          q: expected_query,
          geo: "dst",
          sankey_prefix: "24"
        )

    assert_patch(lv, expected_path)
  end

  test "renders Sankey and Geo panels with SRQL-driven placeholders", %{conn: conn} do
    q = "in:flows time:last_24h"
    {:ok, _lv, html} = live(conn, ~p"/netflows?#{%{q: q, limit: 50}}")

    assert html =~ "Traffic Sankey"
    assert html =~ "Geo Heatmap"
    assert html =~ "Compare"
  end
end
