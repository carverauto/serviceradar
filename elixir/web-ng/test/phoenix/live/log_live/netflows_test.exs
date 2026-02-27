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

  test "/flows renders netflow visualize page", %{conn: conn} do
    q = "in:flows time:last_24h"
    {:ok, _lv, html} = live(conn, ~p"/flows?#{%{q: q, limit: 50}}")
    assert html =~ "Network Flows"
  end

  test "/flows keeps canonical path when patching state", %{conn: conn} do
    q = "in:flows time:last_24h"
    {:ok, lv, _html} = live(conn, ~p"/flows?#{%{q: q, limit: 50}}")

    lv
    |> element("button[phx-click=\"nf_reset\"]")
    |> render_click()

    assert_patch(lv, path)
    assert String.starts_with?(path, "/flows?")
  end
end
