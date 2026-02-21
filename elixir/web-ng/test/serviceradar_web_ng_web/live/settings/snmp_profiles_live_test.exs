defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "renders SNMP profile credentials fields", %{conn: conn} do
    {:ok, lv, html} = live(conn, ~p"/settings/snmp/new")

    assert html =~ "SNMP Credentials"
    assert has_element?(lv, "select[name='form[version]']")
    assert has_element?(lv, "input[name='form[community]']")
  end

  test "edit form keeps stored credentials masked", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])

    {:ok, profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(:create, %{name: "Profile #{unique}", community: "secret"})
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/snmp/#{profile.id}/edit")

    assert has_element?(
             lv,
             "input[name='form[community]'][placeholder='Leave blank to keep existing']"
           )
  end

  test "renders target counts for SNMP profiles", %{conn: conn, scope: scope} do
    unique = System.unique_integer([:positive])
    device_fixture(%{hostname: "target#{unique}"})

    {:ok, profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(:create, %{
        name: "Profile #{unique}",
        poll_interval: 60,
        timeout: 5,
        retries: 3,
        enabled: true,
        target_query: "in:devices hostname:target#{unique}"
      })
      |> Ash.create(scope: scope)

    {:ok, lv, _html} = live(conn, ~p"/settings/snmp")

    assert has_element?(lv, "#snmp-profile-#{profile.id}-targets", "1 target")
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end
end
