defmodule ServiceRadarWebNGWeb.Api.AdminAuthorizationTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Ecto.Query

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Identity.RoleProfile
  alias ServiceRadar.Identity.User
  alias ServiceRadar.Repo
  alias ServiceRadarWebNG.AshTestHelpers

  require Ash.Query

  describe "/api/admin/* authorization" do
    test "denies viewers for role profiles endpoints", %{conn: conn} do
      user = viewer_user_fixture()
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/api/admin/role-profiles")
      body = json_response(conn, 403)
      assert body["error"] == "forbidden" or Map.has_key?(body, "errors")
    end

    test "allows admins for role profiles endpoints", %{conn: conn} do
      user = admin_user_fixture()
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/api/admin/role-profiles")
      assert is_list(json_response(conn, 200))
    end

    @tag :web_ng_shared_fixture_db
    @tag sandbox: :unboxed
    test "rejects a role-profile mutation after persisted RBAC authority is revoked", %{
      conn: conn
    } do
      marker = "controller-authority-#{System.unique_integer([:positive])}"
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

      conn = conn |> log_in_user(user) |> get(~p"/api/admin/role-profiles")
      assert is_list(json_response(conn, 200))
      assert MapSet.member?(RBAC.permissions_for_user(user), "settings.rbac.manage")

      Repo.update_all(
        from(p in "role_profiles", prefix: "platform", where: p.id == ^profile.id),
        set: [permissions: []]
      )

      name = "#{marker}-revoked-request"

      conn =
        conn
        |> recycle()
        |> post(~p"/api/admin/role-profiles", %{
          "name" => name,
          "permissions" => ["devices.view"]
        })

      assert json_response(conn, 403)["error"] == "forbidden"

      assert {:ok, []} =
               RoleProfile
               |> Ash.Query.filter(name == ^name)
               |> Ash.read(actor: system)
    end

    test "denies viewers for users endpoints", %{conn: conn} do
      user = viewer_user_fixture()
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/api/admin/users")
      body = json_response(conn, 403)
      assert body["error"] == "forbidden" or Map.has_key?(body, "errors")
    end

    test "denies viewers for authorization settings endpoints", %{conn: conn} do
      user = viewer_user_fixture()
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/api/admin/authorization-settings")
      body = json_response(conn, 403)
      assert body["error"] == "forbidden" or Map.has_key?(body, "errors")
    end
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
