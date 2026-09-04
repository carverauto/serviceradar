defmodule ServiceRadarWebNGWeb.Settings.RbacLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  test "dashboards section lists authored and package resources without aliased cli keys", %{
    conn: conn
  } do
    admin = AshTestHelpers.admin_user_fixture()

    {:ok, lv, _html} =
      conn
      |> log_in_user(admin)
      |> live(~p"/settings/auth/rbac")

    html =
      lv
      |> element("button[phx-click='select_section'][phx-value-section='dashboards']")
      |> render_click()

    assert html =~ "Authored"
    assert html =~ "Packages"
    refute html =~ "cli.dashboard"
    assert html =~ "publish"
    assert html =~ "share"
    assert html =~ "view all"
  end

  @tag :web_ng_shared_fixture_db
  @tag sandbox: :unboxed
  test "rejects a role-profile mutation after mounted RBAC authority is revoked", %{conn: conn} do
    marker = "live-authority-#{System.unique_integer([:positive])}"
    email = "#{marker}@example.test"
    on_exit(fn -> cleanup_unboxed!(marker, email) end)

    system = AshTestHelpers.system_actor()
    user = AshTestHelpers.admin_user_fixture(%{email: email})
    profile = custom_profile!(system, marker, ["settings.rbac.manage"])

    user
    |> Ash.Changeset.for_update(:update_role_profile, %{role_profile_id: profile.id},
      actor: system
    )
    |> Ash.update!()

    {:ok, live_view, _html} =
      conn
      |> log_in_user(user)
      |> live(~p"/settings/auth/rbac")

    assert MapSet.member?(RBAC.permissions_for_user(user), "settings.rbac.manage")

    Repo.update_all(
      from(p in "role_profiles", prefix: "platform", where: p.id == ^profile.id),
      set: [permissions: []]
    )

    name = "#{marker}-revoked-live"

    live_view
    |> element("button[phx-click='open_new_profile']")
    |> render_click()

    live_view
    |> form("#new-profile-form", profile: %{name: name, description: "Synthetic profile"})
    |> render_submit()

    assert render(live_view) =~ "Unexpected error"

    assert {:ok, []} =
             RoleProfile
             |> Ash.Query.filter(name == ^name)
             |> Ash.read(actor: system)
  end

  defp custom_profile!(actor, marker, permissions) do
    RoleProfile
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "#{marker}-profile",
        permissions: permissions
      },
      actor: actor
    )
    |> Ash.Changeset.set_context(%{privilege_boundary_owned: true})
    |> Ash.create!()
  end

  defp cleanup_unboxed!(marker, email) do
    Repo.delete_all(from(u in "ng_users", prefix: "platform", where: u.email == ^email))

    Repo.delete_all(
      from(p in "role_profiles", prefix: "platform", where: like(p.name, ^"#{marker}%"))
    )
  end
end
