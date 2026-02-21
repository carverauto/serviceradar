defmodule ServiceRadarWebNG.Api.UserControllerTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadar.Identity.User
  alias ServiceRadarWebNG.AshTestHelpers

  setup %{conn: conn} do
    admin = AshTestHelpers.admin_user_fixture()
    conn = log_in_api_user(conn, admin)
    scope = ServiceRadarWebNG.Accounts.Scope.for_user(admin)
    %{conn: conn, admin: admin, scope: scope}
  end

  describe "GET /api/admin/users" do
    test "lists users", %{conn: conn} do
      _user1 = AshTestHelpers.user_fixture()
      _user2 = AshTestHelpers.user_fixture()

      conn = get(conn, ~p"/api/admin/users")
      result = json_response(conn, 200)

      assert is_list(result)
      assert length(result) >= 3
    end

    test "filters by status", %{conn: conn, scope: scope} do
      active_user = AshTestHelpers.user_fixture()

      inactive_user = AshTestHelpers.user_fixture()

      inactive_user
      |> Ash.Changeset.for_update(:deactivate, %{}, scope: scope)
      |> Ash.update!(scope: scope)

      conn = get(conn, ~p"/api/admin/users?status=active")
      result = json_response(conn, 200)

      assert Enum.any?(result, &(&1["id"] == active_user.id))
      assert Enum.all?(result, &(&1["status"] == "active"))
    end

    test "filters by role", %{conn: conn} do
      admin_user = AshTestHelpers.admin_user_fixture()
      _viewer = AshTestHelpers.user_fixture()

      conn = get(conn, ~p"/api/admin/users?role=admin")
      result = json_response(conn, 200)

      assert Enum.any?(result, &(&1["id"] == admin_user.id))
      assert Enum.all?(result, &(&1["role"] == "admin"))
    end
  end

  describe "POST /api/admin/users" do
    test "creates a user with default role", %{conn: conn} do
      params = %{
        "email" => "new-user@example.com",
        "display_name" => "New User"
      }

      conn = post(conn, ~p"/api/admin/users", params)
      result = json_response(conn, 201)

      assert result["email"] == "new-user@example.com"
      assert result["role"] == "viewer"
      assert result["status"] == "active"
    end

    test "creates a user with explicit role", %{conn: conn} do
      params = %{
        "email" => "operator@example.com",
        "display_name" => "Operator",
        "role" => "operator"
      }

      conn = post(conn, ~p"/api/admin/users", params)
      result = json_response(conn, 201)

      assert result["role"] == "operator"
    end

    test "rejects invalid role", %{conn: conn} do
      params = %{
        "email" => "badrole@example.com",
        "role" => "superadmin"
      }

      conn = post(conn, ~p"/api/admin/users", params)

      assert json_response(conn, 400)["error"] =~ "role must be one of"
    end
  end

  describe "PATCH /api/admin/users/:id" do
    test "updates role", %{conn: conn} do
      user = AshTestHelpers.user_fixture()

      conn = patch(conn, ~p"/api/admin/users/#{user.id}", %{"role" => "operator"})
      result = json_response(conn, 200)

      assert result["role"] == "operator"
    end

    test "updates display name", %{conn: conn} do
      user = AshTestHelpers.user_fixture()

      conn = patch(conn, ~p"/api/admin/users/#{user.id}", %{"display_name" => "New Name"})
      result = json_response(conn, 200)

      assert result["display_name"] == "New Name"
    end

    test "rejects invalid role", %{conn: conn} do
      user = AshTestHelpers.user_fixture()

      conn = patch(conn, ~p"/api/admin/users/#{user.id}", %{"role" => "invalid"})

      assert json_response(conn, 400)["error"] =~ "role must be one of"
    end
  end

  describe "POST /api/admin/users/:id/deactivate" do
    test "deactivates a user", %{conn: conn, scope: scope} do
      user = AshTestHelpers.user_fixture()

      conn = post(conn, ~p"/api/admin/users/#{user.id}/deactivate")
      result = json_response(conn, 200)

      assert result["status"] == "inactive"

      {:ok, reloaded} = Ash.get(User, user.id, scope: scope)
      assert reloaded.status == :inactive
    end
  end

  describe "POST /api/admin/users/:id/reactivate" do
    test "reactivates a user", %{conn: conn, scope: scope} do
      user = AshTestHelpers.user_fixture()

      user
      |> Ash.Changeset.for_update(:deactivate, %{}, scope: scope)
      |> Ash.update!(scope: scope)

      conn = post(conn, ~p"/api/admin/users/#{user.id}/reactivate")
      result = json_response(conn, 200)

      assert result["status"] == "active"

      {:ok, reloaded} = Ash.get(User, user.id, scope: scope)
      assert reloaded.status == :active
    end
  end

  describe "admin access" do
    test "non-admin is forbidden", %{conn: conn} do
      viewer = AshTestHelpers.user_fixture()
      conn = log_in_api_user(conn, viewer)

      conn = get(conn, ~p"/api/admin/users")
      assert json_response(conn, 403)["errors"]["detail"] == "Forbidden"
    end
  end
end
