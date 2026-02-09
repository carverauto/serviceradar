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

  test "legacy /netflows redirects to /netflow preserving SRQL params", %{conn: conn} do
    q = "in:flows time:last_24h"
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/netflows?#{%{q: q, limit: 50}}")

    uri = URI.parse(to)
    assert uri.path == "/netflow"

    params = Plug.Conn.Query.decode(uri.query || "")
    assert params["q"] == q
    assert params["limit"] == "50"
  end

  test "netflow visualize page renders after redirect", %{conn: conn} do
    q = "in:flows time:last_24h"
    assert {:error, {:redirect, %{to: to}}} = live(conn, ~p"/netflows?#{%{q: q, limit: 50}}")

    {:ok, _lv, html} = live(conn, to)
    assert html =~ "NetFlow Visualize"
  end
end
