defmodule ServiceRadarWebNGWeb.Settings.SysmonProfilesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.AshTestHelpers

  setup %{conn: conn} do
    user = AshTestHelpers.admin_user_fixture()

    %{
      conn: log_in_user(conn, user),
      user: user,
      scope: ServiceRadarWebNG.Accounts.Scope.for_user(user)
    }
  end

  test "syncs builder when SRQL query is pasted", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/sysmon/new")

    lv
    |> element("button[phx-click='builder_toggle']")
    |> render_click()

    query =
      ~s(in:devices uid:"sr:a24204a8-9989-43e9-b9da-df7eb2f9bb7e" limit:50)

    lv
    |> form("#sysmon-profile-form", form: %{target_query: query})
    |> render_change()

    assert has_element?(
             lv,
             "select[name='builder[filters][0][field]'] option[value='uid'][selected]"
           )

    assert has_element?(
             lv,
             "input[name='builder[filters][0][value]'][value*='sr:']"
           )

    refute has_element?(lv, "button[phx-click='builder_apply']")
  end

  test "marks builder as not applied for unsupported SRQL", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/settings/sysmon/new")

    lv
    |> element("button[phx-click='builder_toggle']")
    |> render_click()

    query =
      ~s(in:devices uid:"sr:a24204a8-9989-43e9-b9da-df7eb2f9bb7e" OR hostname:db-01)

    lv
    |> form("#sysmon-profile-form", form: %{target_query: query})
    |> render_change()

    assert has_element?(lv, "button[phx-click='builder_apply']")
  end
end
