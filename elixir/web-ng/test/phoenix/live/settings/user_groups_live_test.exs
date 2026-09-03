defmodule ServiceRadarWebNGWeb.Settings.UserGroupsLiveTest do
  @moduledoc """
  The Settings -> User Groups list has to show groups operators already
  configured as identity-provider mappings, not only groups created on this
  page. Otherwise the page looks empty while users already have group-based
  access.
  """

  use ServiceRadarWebNGWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.AuthorizationSettings
  alias ServiceRadar.Identity.UserGroup
  alias ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  test "shows identity-provider group mappings as user groups", %{conn: conn} do
    group_name = "network-ops-#{System.unique_integer([:positive])}"
    settings!([%{"source" => "groups", "value" => group_name, "role" => "operator"}])
    admin = AshTestHelpers.admin_user_fixture()

    {:ok, view, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/settings/user-groups")

    html = render_async(view, 5_000)

    assert html =~ group_name
    refute html =~ "No user groups have been created yet."
  end

  test "lists a group created as a reusable user group", %{conn: conn} do
    admin = AshTestHelpers.admin_user_fixture()
    actor = SystemActor.system(:user_groups_live_test)
    group_name = "share-#{System.unique_integer([:positive])}"

    {:ok, _group} = UserGroup.create_group(%{name: group_name}, actor: actor)

    {:ok, view, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/settings/user-groups")

    html = render_async(view, 5_000)

    assert html =~ group_name
    refute html =~ "No user groups have been created yet."
  end

  defp settings!(mappings) do
    actor = SystemActor.system(:user_groups_live_test)
    attrs = %{default_role: :viewer, role_mappings: mappings}

    case AuthorizationSettings.get_settings(actor: actor) do
      {:ok, %AuthorizationSettings{} = existing} ->
        {:ok, settings} = AuthorizationSettings.update_settings(existing, attrs, actor: actor)
        settings

      _not_found ->
        {:ok, settings} = AuthorizationSettings.create_settings(attrs, actor: actor)
        settings
    end
  end
end
