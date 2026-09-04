defmodule ServiceRadarWebNGWeb.DeviceLive.NorthboundActionAuthorizationLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadarWebNG.AccountsFixtures
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.Repo

  setup %{conn: conn} do
    user =
      %{role: :viewer}
      |> AccountsFixtures.user_fixture()
      |> grant_permissions(["devices.view"])

    uid = "northbound-forged-event-#{System.unique_integer([:positive])}"

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "northbound-forged-event-host",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z]
      }
    ])

    %{conn: log_in_user(conn, user), uid: uid}
  end

  test "device-list change and submit events reject a forged northbound launch", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/devices?limit=10")

    params = %{"action" => %{"action_id" => Ash.UUID.generate(), "input" => %{}}}

    assert render_hook(view, "northbound_action_change", params) =~
             "Missing permission: northbound.actions.launch"

    assert render_hook(view, "launch_northbound_action", params) =~
             "Missing permission: northbound.actions.launch"
  end

  test "interface change and submit events reject a forged northbound launch", %{
    conn: conn,
    uid: uid
  } do
    {:ok, view, _html} = live(conn, ~p"/devices/#{uid}")

    params = %{"action" => %{"action_id" => Ash.UUID.generate(), "input" => %{}}}

    assert render_hook(view, "northbound_interface_action_change", params) =~
             "Missing permission: northbound.actions.launch"

    assert render_hook(view, "launch_northbound_interface_action", params) =~
             "Missing permission: northbound.actions.launch"
  end

  defp grant_permissions(user, permissions) do
    actor = AshTestHelpers.system_actor()

    profile =
      RoleProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Northbound denial #{System.unique_integer([:positive])}",
          description: "Exact permissions for forged northbound event coverage",
          permissions: permissions
        },
        actor: actor,
        context: %{privilege_boundary_owned: true}
      )
      |> Ash.create!()

    updated =
      user
      |> Ash.Changeset.for_update(
        :update_role_profile,
        %{role_profile_id: profile.id},
        actor: actor
      )
      |> Ash.update!()

    RBAC.clear_process_cache()
    RBAC.Cache.put(updated.id, MapSet.new(permissions))
    updated
  end
end
