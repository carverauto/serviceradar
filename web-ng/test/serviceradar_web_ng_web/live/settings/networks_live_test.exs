defmodule ServiceRadarWebNGWeb.Settings.NetworksLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.SweepJobs.{SweepGroup, SweepProfile}
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "lists sweep groups on the groups tab", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, group} =
      SweepGroup
      |> Ash.Changeset.for_create(:create, %{name: "Group #{unique}"})
      |> Ash.create(scope: scope)

    {:ok, _lv, html} = live(conn, ~p"/settings/networks")

    assert html =~ "Sweep Groups"
    assert html =~ group.name
  end

  test "switches to profiles tab and lists profiles", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, profile} =
      SweepProfile
      |> Ash.Changeset.for_create(:create, %{name: "Profile #{unique}"})
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/networks")

    html =
      lv
      |> element("button[phx-value-tab='profiles']")
      |> render_click()

    assert html =~ "Scanner Profiles"
    assert html =~ profile.name
  end

  test "renders new sweep group form and adds a rule", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings/networks/groups/new")

    assert html =~ "New Sweep Group"
    assert html =~ "Targeting Rules"

    html =
      lv
      |> element("button", "Add Tag")
      |> render_click()

    assert html =~ "Rule"
  end

  test "renders new scanner profile form", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/networks/profiles/new")

    assert html =~ "New Scanner Profile"
    assert html =~ "Sweep Modes"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end
end
