defmodule ServiceRadarWebNGWeb.Api.AdminAuthorizationTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  import ServiceRadarWebNG.AshTestHelpers,
    only: [admin_user_fixture: 0, viewer_user_fixture: 0]

  describe "/api/admin/* authorization" do
    test "denies viewers for role profiles endpoints", %{conn: conn} do
      user = viewer_user_fixture()
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/api/admin/role-profiles")
      assert %{"errors" => _} = json_response(conn, 403)
    end

    test "allows admins for role profiles endpoints", %{conn: conn} do
      user = admin_user_fixture()
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/api/admin/role-profiles")
      assert is_list(json_response(conn, 200))
    end

    test "denies viewers for users endpoints", %{conn: conn} do
      user = viewer_user_fixture()
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/api/admin/users")
      assert %{"errors" => _} = json_response(conn, 403)
    end

    test "denies viewers for authorization settings endpoints", %{conn: conn} do
      user = viewer_user_fixture()
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/api/admin/authorization-settings")
      assert %{"errors" => _} = json_response(conn, 403)
    end
  end
end
