defmodule ServiceRadarWebNGWeb.EventLive.IndexTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AccountsFixtures

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :operator})
    conn = log_in_user(conn, user)
    %{conn: conn}
  end

  test "redirects /events to Observability events tab", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/events")
    assert to =~ "/observability"
    assert to =~ "tab=events"
  end

  test "preserves SRQL query when redirecting", %{conn: conn} do
    q = "in:events severity:High time:last_7d sort:time:desc"

    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, ~p"/events?#{%{q: q, limit: 20}}")

    assert to =~ "/observability"
    assert to =~ "tab=events"
    assert to =~ URI.encode_query(%{q: q}) or to =~ "q="
    assert to =~ "limit=20"
  end
end
