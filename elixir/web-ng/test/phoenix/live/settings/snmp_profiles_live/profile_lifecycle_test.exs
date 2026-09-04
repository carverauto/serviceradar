defmodule ServiceRadarWebNGWeb.Settings.SNMPProfilesLive.ProfileLifecycleTest do
  @moduledoc """
  Retiring an SNMP profile from the settings UI. GitHub #4170.

  The default profile row used to offer nothing but the edit pencil: both
  `set_default` and `delete_profile` are hidden by `:if={!profile.is_default}`,
  and enable/disable was a bare unstyled `<button>` around a status dot, which
  reads as static text. An operator on an instance whose only profile is the
  seeded default had no way to turn SNMP off or remove the profile.
  """
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  require Ash.Query

  # The database-free unit tier loads this file but cannot run it. This tag is
  # what assigns the cases to //elixir/web-ng:networks_live_db_test, the lane
  # that has a database; without it they would be silently excluded.
  @moduletag :web_ng_shared_fixture_db

  setup :register_and_log_in_admin_user
  setup :retire_existing_profiles

  # The fixture database has run the migrations, one of which seeds
  # "Default SNMP". Starting from a known-empty list is what lets these tests
  # assert on the empty state and on exactly one row. The sandbox rolls this
  # back after each test.
  defp retire_existing_profiles(_context) do
    actor = admin_actor()

    SNMPProfile
    |> Ash.read!(actor: actor)
    |> Enum.each(fn profile ->
      profile =
        if profile.is_default do
          profile
          |> Ash.Changeset.for_update(:unset_default, %{}, actor: actor)
          |> Ash.update!(actor: actor)
        else
          profile
        end

      :ok = Ash.destroy(profile, actor: actor)
    end)

    :ok
  end

  describe "the default profile row" do
    test "offers an explicit disable control", %{conn: conn} do
      profile = profile_fixture(is_default: true)

      {:ok, lv, _html} = live(conn, ~p"/settings/snmp")

      assert has_element?(lv, "[phx-click='toggle_profile'][phx-value-id='#{profile.id}']"),
             "the default profile must be disableable -- it is the only lever that retires it in place"

      lv
      |> element("[phx-click='toggle_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      assert %{enabled: false} = reload(profile)
    end

    test "offers a clear-default control and hides delete until the flag is cleared", %{conn: conn} do
      profile = profile_fixture(is_default: true)

      {:ok, lv, _html} = live(conn, ~p"/settings/snmp")

      refute has_element?(lv, "[phx-click='delete_profile'][phx-value-id='#{profile.id}']"),
             "destroy is forbidden while is_default is true, so the button must not be offered"

      assert has_element?(lv, "[phx-click='clear_default'][phx-value-id='#{profile.id}']")

      lv
      |> element("[phx-click='clear_default'][phx-value-id='#{profile.id}']")
      |> render_click()

      assert %{is_default: false} = reload(profile)

      assert has_element?(lv, "[phx-click='delete_profile'][phx-value-id='#{profile.id}']"),
             "once demoted the profile must become deletable without a page reload"
    end

    test "deleting the demoted profile leaves the instance with no profile at all", %{conn: conn} do
      profile = profile_fixture(is_default: false)

      {:ok, lv, _html} = live(conn, ~p"/settings/snmp")

      lv
      |> element("[phx-click='delete_profile'][phx-value-id='#{profile.id}']")
      |> render_click()

      assert {:error, _} = Ash.get(SNMPProfile, profile.id, actor: admin_actor())
      assert render(lv) =~ "No SNMP profiles configured"
    end
  end

  # Defined per file across this suite rather than shared from ConnCase; see
  # snmp_profiles_live_test.exs and the other settings LiveView tests.
  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp reload(%{id: id}) do
    Ash.get!(SNMPProfile, id, actor: admin_actor())
  end

  defp profile_fixture(opts) do
    attrs = %{
      name: "lifecycle-#{System.unique_integer([:positive])}",
      poll_interval: 60,
      timeout: 5,
      retries: 3,
      target_query: "in:devices",
      is_default: Keyword.get(opts, :is_default, false)
    }

    SNMPProfile
    |> Ash.Changeset.for_create(:create, attrs, actor: admin_actor())
    |> Ash.create!(actor: admin_actor())
  end
end
