defmodule ServiceRadarWebNGWeb.Settings.NetworkCredentialRulesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "renders the credential rules settings route", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/credentials")

    assert html =~ "Credential Rules"
    assert html =~ "No credential rules found"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end
end
